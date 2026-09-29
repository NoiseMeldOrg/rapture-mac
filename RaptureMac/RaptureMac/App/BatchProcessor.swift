import Foundation
import OSLog

/// Per-batch decision contract. The integer counts roll up to the caller for the optional catch-up summary.
struct BatchOutcome: Equatable {
    var successCount: Int
    var failureCount: Int
    var droppedCount: Int
    var isCatchup: Bool
}

protocol FileWriting: Sendable {
    func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult
}

extension FileWriter: FileWriting {}

/// Encapsulates per-batch orchestration: filter → echo check → write → reply.
///
/// First non-empty batch with `count > 3` is flagged as catchup; subsequent batches are live.
/// Extracted from Pipeline so the catch-up decision logic can be unit-tested without chat.db.
@MainActor
final class BatchProcessor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "BatchProcessor")

    /// Triggers catch-up on the *first* non-empty batch (sleep/quit recovery on launch).
    nonisolated static let catchupThreshold = 3

    /// Triggers catch-up on *any* batch this size or larger, regardless of first-seen state.
    /// Live usage produces 1–2 events per poll; a backlog from iCloud re-sync, Mac wake-from-sleep,
    /// or any other anomaly surfaces 10+ events at once. Treating those as catch-up suppresses
    /// per-message replies (one summary instead) — the load-bearing protection against
    /// the v1.0.18 echo-cascade incident.
    nonisolated static let backlogThreshold = 10

    /// How many recent `message.guid` values to remember for cross-row dedup. iCloud sync
    /// re-delivers a single logical iMessage to chat.db once per paired device — each
    /// delivery has its own ROWID but the same `message.guid`. Without dedup, one
    /// Siri-dictated note becomes 3–4 captured files.
    nonisolated static let recentGuidCapacity = 500

    /// A failed capture is retried this often while it stays unresolved.
    nonisolated static let failureRetryBackoff: TimeInterval = 60

    /// After this long failing, a capture's text is rescued to
    /// `Failed captures/` and its row released, so one bad row can't pin the
    /// watermark (and re-read every later message) forever.
    nonisolated static let giveUpAfter: TimeInterval = 24 * 60 * 60

    /// How long batches wait for the user's own iMessage addresses to become
    /// known, and how often the lookup is re-run meanwhile.
    nonisolated static let selfHandleGrace: TimeInterval = 10 * 60
    nonisolated static let selfHandleRefreshInterval: TimeInterval = 10

    /// Pure helper for the catch-up decision. Unit-testable in isolation.
    nonisolated static func isCatchup(batchSize: Int, isFirstNonemptyBatchSeen: Bool) -> Bool {
        if batchSize >= backlogThreshold { return true }
        return !isFirstNonemptyBatchSeen && batchSize > catchupThreshold
    }

    /// Pure helper for the GUID-dedup decision. Returns the new GUID buffer plus a flag
    /// indicating whether this event is a duplicate of a recently-seen GUID. Unit-testable.
    nonisolated static func dedupCheck(
        guid: String,
        recent: [String],
        capacity: Int
    ) -> (isDuplicate: Bool, updatedRecent: [String]) {
        // Empty GUIDs are a defensive default for missing data; don't treat as duplicate.
        guard !guid.isEmpty else { return (false, recent) }
        if recent.contains(guid) { return (true, recent) }
        var updated = recent
        updated.append(guid)
        if updated.count > capacity {
            updated.removeFirst(updated.count - capacity)
        }
        return (false, updated)
    }

    /// Per-batch policy resolution: defer vs process, plus the next-batch state.
    /// Pure so the pause/resume flow is unit-testable without an AppState.
    struct Policy: Equatable {
        /// `true` means: hold the batch, do not advance the watermark, do not write or reply.
        var deferred: Bool
        /// When not deferred, whether this batch is the catch-up trigger.
        var isCatchup: Bool
        /// Next value of `isFirstNonemptyBatchSeen` after this batch returns.
        var nextIsFirstNonemptyBatchSeen: Bool
        /// Next value of `wasPausedLastBatch` after this batch returns.
        var nextWasPausedLastBatch: Bool
    }

    nonisolated static func policy(
        paused: Bool,
        wasPausedLastBatch: Bool,
        isFirstNonemptyBatchSeen: Bool,
        batchSize: Int
    ) -> Policy {
        if paused {
            return Policy(
                deferred: true,
                isCatchup: false,
                nextIsFirstNonemptyBatchSeen: isFirstNonemptyBatchSeen,
                nextWasPausedLastBatch: true
            )
        }
        // Just unpaused: re-evaluate this batch as a potential catch-up trigger.
        let firstSeenForDecision = wasPausedLastBatch ? false : isFirstNonemptyBatchSeen
        let catchup = isCatchup(batchSize: batchSize, isFirstNonemptyBatchSeen: firstSeenForDecision)
        return Policy(
            deferred: false,
            isCatchup: catchup,
            nextIsFirstNonemptyBatchSeen: true,
            nextWasPausedLastBatch: false
        )
    }

    private let appState: AppState
    private let writer: FileWriting
    private let replier: Replier
    private let echoGuard: EchoGuard
    private let contentDedupCache: ContentDedupCache
    private let spool: SpoolStore
    private let destinationGuard: DestinationGuard
    /// Reminders/Calendar handoff, fired on the direct-write success path only.
    /// A spooled capture hands off at flush time (`DestinationMonitor`) — the
    /// note isn't filed yet when it spools. Optional so existing tests and
    /// callers without handoff are unchanged.
    private let handoff: (any HandoffProcessing)?
    /// Link enrichment (M5), enqueued on the direct-write success path only —
    /// a spooled capture enriches at flush time (`DestinationMonitor`).
    private let enrichment: (any LinkEnriching)?
    private let selfHandlesProvider: @MainActor () -> Set<String>
    private let selfChatGuidProvider: @MainActor () -> String?
    private let advanceWatermark: @MainActor (Int64) -> Void

    private var isFirstNonemptyBatchSeen = false
    private var wasPausedLastBatch = false
    private var recentGuids: [String] = []

    /// Captures whose write failed, keyed by `failureKey`. Their rows stay
    /// unresolved (watermark held) and are retried after `failureRetryBackoff`.
    private struct PendingFailure {
        var firstAt: Date
        var lastAt: Date
        var attempts: Int
    }
    private var pendingFailures: [String: PendingFailure] = [:]
    private let attachmentRetrier: AttachmentRetrier?
    private let clock: @Sendable () -> Date
    private let refreshSelfHandles: (@MainActor () async -> Set<String>)?
    private var selfHandlesEmptySince: Date?
    private var lastSelfHandleRefresh: Date?

    init(
        appState: AppState,
        writer: FileWriting,
        replier: Replier,
        echoGuard: EchoGuard,
        contentDedupCache: ContentDedupCache,
        spool: SpoolStore,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        enrichment: (any LinkEnriching)? = nil,
        selfHandlesProvider: @escaping @MainActor () -> Set<String>,
        selfChatGuidProvider: @escaping @MainActor () -> String?,
        advanceWatermark: @escaping @MainActor (Int64) -> Void,
        attachmentRetrier: AttachmentRetrier? = nil,
        refreshSelfHandles: (@MainActor () async -> Set<String>)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.writer = writer
        self.replier = replier
        self.echoGuard = echoGuard
        self.contentDedupCache = contentDedupCache
        self.spool = spool
        self.destinationGuard = destinationGuard
        self.handoff = handoff
        self.enrichment = enrichment
        self.selfHandlesProvider = selfHandlesProvider
        self.selfChatGuidProvider = selfChatGuidProvider
        self.advanceWatermark = advanceWatermark
        self.attachmentRetrier = attachmentRetrier
        self.clock = clock
        self.refreshSelfHandles = refreshSelfHandles
    }

    @discardableResult
    func process(batch: [MessageEvent]) async -> BatchOutcome {
        // Hold the capture gate for the whole batch so an output-folder relocation can't
        // run while this batch is mid-write, and so the folder URL captured below can't go
        // stale mid-batch. The relocator acquires the same gate before moving files.
        let outcome = await appState.captureGate.withLock {
            await processLocked(batch: batch)
        }
        // Replies go out after the gate is released, in the order they were
        // queued: a slow Messages.app (or the one-time permission prompt) must
        // never hold up the relay, triage, or a relocation. Every note is
        // already on disk by now.
        let replies = pendingReplies
        pendingReplies.removeAll()
        for reply in replies {
            await reply()
        }
        return outcome
    }

    /// Replies queued while the capture gate is held; sent by `process(batch:)`.
    private var pendingReplies: [@MainActor () async -> Void] = []

    private func queueReply(_ reply: @escaping @MainActor () async -> Void) {
        pendingReplies.append(reply)
    }

    private func processLocked(batch: [MessageEvent]) async -> BatchOutcome {
        guard !batch.isEmpty else {
            return BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: false)
        }

        let settings = appState.settings.settings
        let decision = Self.policy(
            // Treat an in-flight relocation like a pause: defer the batch (watermark does
            // not advance) so these rows replay into the new folder once the move completes.
            paused: settings.paused || appState.isRelocating,
            wasPausedLastBatch: wasPausedLastBatch,
            isFirstNonemptyBatchSeen: isFirstNonemptyBatchSeen,
            batchSize: batch.count
        )

        if decision.deferred {
            wasPausedLastBatch = decision.nextWasPausedLastBatch
            Self.log.debug("paused: deferring batch of \(batch.count)")
            return BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: false)
        }

        isFirstNonemptyBatchSeen = decision.nextIsFirstNonemptyBatchSeen
        wasPausedLastBatch = decision.nextWasPausedLastBatch
        let isCatchup = decision.isCatchup

        var outcome = BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: isCatchup)
        var handles = selfHandlesProvider()

        // Own addresses not known yet (the lookup failed, or this Mac has no
        // sent-message rows yet, as on a brand-new setup whose very first
        // "text me" is arriving now): every self-note would drop as "not
        // allowlisted" and the watermark would move past it for good. Hold
        // the batch and re-run the lookup (throttled) until the sent copy of
        // the note syncs in. Bounded: a Mac that never sends iMessages has no
        // self rows at all, and after the grace the allowlist alone decides.
        if handles.isEmpty, let refreshSelfHandles {
            let now = clock()
            let since = selfHandlesEmptySince ?? now
            selfHandlesEmptySince = since
            if now.timeIntervalSince(since) < Self.selfHandleGrace {
                if lastSelfHandleRefresh.map({ now.timeIntervalSince($0) >= Self.selfHandleRefreshInterval }) ?? true {
                    lastSelfHandleRefresh = now
                    handles = await refreshSelfHandles()
                }
                if handles.isEmpty {
                    Self.log.info("self handles unknown yet: deferring batch of \(batch.count)")
                    return BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: false)
                }
            }
        }

        // The watermark may only move past rows that are resolved. Once a row
        // fails (or waits out its retry backoff), no later row may advance the
        // watermark past it in this batch; later rows still file, and their
        // guids keep them from filing twice when the rows replay.
        var holdBelow: Int64?
        func advance(_ rowid: Int64) {
            if let holdBelow, rowid >= holdBelow { return }
            advanceWatermark(rowid)
        }
        func hold(_ rowid: Int64) {
            holdBelow = min(holdBelow ?? rowid, rowid)
        }
        func resolve(_ event: MessageEvent) {
            recentGuids = Self.dedupCheck(guid: event.guid, recent: recentGuids, capacity: Self.recentGuidCapacity).updatedRecent
            pendingFailures[Self.failureKey(event)] = nil
        }

        for event in batch {
            // GUID-based dedup: iCloud sync delivers each logical message to chat.db
            // once per paired device, each with a different ROWID but the same
            // `message.guid`. Without this check, one Siri-dictated note becomes
            // 3–4 captured files. A guid is remembered only once its row is
            // resolved (filed, queued, or dropped) — never on a failed write, or
            // the replay of that row would be mistaken for a duplicate and the
            // note lost (the pre-1.0.126 bug).
            if Self.dedupCheck(guid: event.guid, recent: recentGuids, capacity: Self.recentGuidCapacity).isDuplicate {
                Self.log.debug("dedup-suppressed rowid=\(event.rowid) guid=\(event.guid, privacy: .public)")
                advance(event.rowid)
                outcome.droppedCount += 1
                continue
            }

            // A row that failed recently waits out its backoff, still unresolved.
            let key = Self.failureKey(event)
            if let pending = pendingFailures[key],
               clock().timeIntervalSince(pending.lastAt) < Self.failureRetryBackoff {
                hold(event.rowid)
                continue
            }

            let decision = MessageFilter.decide(
                event: event,
                selfHandles: handles,
                settings: settings,
                isCatchup: isCatchup
            )

            switch decision {
            case .drop(let reason):
                Self.log.debug("dropped rowid=\(event.rowid) reason=\(reason.rawValue, privacy: .public)")
                resolve(event)
                advance(event.rowid)
                outcome.droppedCount += 1

            case .capture(let captured):
                if let chatGuid = captured.event.chatGuid,
                   echoGuard.consume(chatGuid: chatGuid, text: captured.decodedText) {
                    Self.log.debug("echo-suppressed rowid=\(event.rowid)")
                    resolve(event)
                    advance(event.rowid)
                    outcome.droppedCount += 1
                    continue
                }

                // Cross-session content dedup. Catches iCloud cross-device replays
                // that GUID dedup can't see (different GUIDs, different timestamps,
                // identical content). The check happens here rather than in
                // MessageFilter because it depends on cross-batch persisted state.
                let handleForDedup = captured.event.handleId ?? ""
                if contentDedupCache.contains(
                    handle: handleForDedup,
                    text: captured.decodedText,
                    attachmentCount: captured.event.attachments.count
                ) {
                    Self.log.debug("content-dedup suppressed rowid=\(event.rowid)")
                    resolve(event)
                    advance(event.rowid)
                    outcome.droppedCount += 1
                    continue
                }

                guard let folder = settings.outputFolder else {
                    if await failed(captured, key: key, reason: "No output folder configured", result: nil, settings: settings) {
                        resolve(event)
                        advance(event.rowid)
                    } else {
                        hold(event.rowid)
                    }
                    outcome.failureCount += pendingFailures[key]?.attempts == 1 ? 1 : 0
                    continue
                }

                // Spool instead of writing when the destination's volume is absent
                // — or when older captures are already queued: writing ahead of the
                // spool would break the flush's original-capture-order guarantee.
                // The guard runs synchronously inside the capture gate, so it can't
                // race the monitor's flush.
                let volumeAbsent = destinationGuard.check(folder) == .volumeAbsent
                if volumeAbsent || !spool.isEmpty {
                    if await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, destinationOffline: volumeAbsent, outcome: &outcome) {
                        resolve(event)
                        advance(event.rowid)
                    } else {
                        hold(event.rowid)
                    }
                    continue
                }

                let result = await writer.write(captured, to: folder, mode: settings.triageMode)
                switch result.outcome {
                case .success(let url):
                    Self.log.info("wrote \(url.lastPathComponent, privacy: .public) (rowid=\(event.rowid))")
                    let wasRetry = pendingFailures[key] != nil
                    resolve(event)
                    appState.clearError(source: .capture)
                    appState.state.recordSuccess(at: Date())
                    appState.activity.record(
                        .filed, source: .iMessage,
                        wasRetry ? "\(Self.noteName(url)) (filed on retry)" : Self.noteName(url),
                        path: url
                    )
                    advance(event.rowid)
                    outcome.successCount += 1
                    contentDedupCache.track(
                        handle: handleForDedup,
                        text: captured.decodedText,
                        attachmentCount: captured.event.attachments.count
                    )
                    if !result.failedAttachments.isEmpty {
                        attachmentMissing(url: url, captured: captured, failedSourcePaths: result.failedAttachments, source: .iMessage)
                    }
                    // Enrichment after the note durably filed (M5): enqueue only,
                    // never blocks the batch.
                    if let enrichment, let echo = result.link {
                        enrichment.noteFiled(noteURL: url, in: folder, echo: echo)
                    }
                    // Handoff after the note durably filed, before the reply so
                    // the outcome can suffix the confirmation.
                    var handoffOutcome = HandoffOutcome.none
                    if let handoff {
                        handoffOutcome = await handoff.process(
                            text: captured.decodedText,
                            capturedAt: captured.event.dateUTC,
                            ai: result.ai
                        )
                    }
                    queueReply { [replier, handoffOutcome] in
                        await replier.replyForWrite(
                            captured: captured, result: result, settings: settings, handoff: handoffOutcome
                        )
                    }
                case .failure(let reason):
                    if destinationGuard.check(folder) == .volumeAbsent {
                        // The unplug raced the write: the failure IS the absence.
                        if await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, destinationOffline: true, outcome: &outcome) {
                            resolve(event)
                            advance(event.rowid)
                        } else {
                            hold(event.rowid)
                        }
                        continue
                    }
                    Self.log.error("write failed rowid=\(event.rowid): \(reason, privacy: .public)")
                    if await failed(captured, key: key, reason: reason, result: result, settings: settings) {
                        resolve(event)
                        advance(event.rowid)
                    } else {
                        hold(event.rowid)
                    }
                    if pendingFailures[key]?.attempts == 1 { outcome.failureCount += 1 }
                case .unavailable:
                    // The writer's internal guard fired (defense in depth).
                    if await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, destinationOffline: true, outcome: &outcome) {
                        resolve(event)
                        advance(event.rowid)
                    } else {
                        hold(event.rowid)
                    }
                }
            }
        }

        if isCatchup {
            let summary = outcome
            let selfChatGuid = selfChatGuidProvider()
            queueReply { [replier] in
                await replier.sendCatchupSummary(
                    successCount: summary.successCount,
                    failureCount: summary.failureCount,
                    selfChatGuid: selfChatGuid,
                    replyMode: settings.replyMode
                )
            }
        }

        return outcome
    }

    /// Queues a capture in the internal spool. The spool write is durable (boot
    /// volume), so this IS the capture: the watermark advances, the today count
    /// increments, dedup tracks, and the honest queued confirmation goes out.
    /// The flush later files it without re-counting or re-replying.
    private func spoolCapture(
        _ captured: CapturedMessage,
        handleForDedup: String,
        settings: Settings,
        destinationOffline: Bool,
        outcome: inout BatchOutcome
    ) async -> Bool {
        do {
            let item = try await spool.add(
                text: captured.decodedText,
                capturedAt: captured.event.dateUTC,
                source: .raptureMac,
                attachments: captured.event.attachments
            )
            Self.log.info("spooled rowid=\(captured.event.rowid) as \(item.name, privacy: .public) (destination offline)")
            appState.state.recordSuccess(at: Date())
            appState.clearError(source: .queue)
            appState.activity.record(.queued, source: .iMessage, Self.titleHint(captured.decodedText))
            outcome.successCount += 1
            contentDedupCache.track(
                handle: handleForDedup,
                text: captured.decodedText,
                attachmentCount: captured.event.attachments.count
            )
            queueReply { [replier] in
                await replier.replyForSpooled(
                    captured: captured, settings: settings,
                    destinationOffline: destinationOffline
                )
            }
            return true
        } catch {
            // Spool write failed (app-support container unwritable — should not
            // happen). The row stays unresolved: watermark held, retried after
            // the backoff, rescued after the give-up window like a failed write.
            let reason = "Couldn't queue capture: \(error.localizedDescription)"
            Self.log.error("\(reason, privacy: .public)")
            let key = Self.failureKey(captured.event)
            if await failed(captured, key: key, reason: reason, result: nil, settings: settings) {
                return true
            }
            if pendingFailures[key]?.attempts == 1 { outcome.failureCount += 1 }
            return false
        }
    }

    // MARK: - Failures, retries, rescue

    /// Records one failed attempt for a capture. First attempt: error, activity
    /// entry, and the ✗ reply. Later attempts: silent. Past `giveUpAfter`, the
    /// capture's text is rescued to a file and the row is released. Returns
    /// true when the row is resolved (rescued) and may be passed.
    private func failed(
        _ captured: CapturedMessage,
        key: String,
        reason: String,
        result: WriteResult?,
        settings: Settings
    ) async -> Bool {
        let now = clock()
        var pending = pendingFailures[key] ?? PendingFailure(firstAt: now, lastAt: now, attempts: 0)
        pending.attempts += 1
        pending.lastAt = now

        if now.timeIntervalSince(pending.firstAt) >= Self.giveUpAfter {
            pendingFailures[key] = nil
            let rescued = rescue(captured)
            let when = captured.event.dateUTC.formatted(date: .abbreviated, time: .shortened)
            let message = rescued.map { "Gave up filing a note from \(when). Its text is saved in \($0.lastPathComponent)." }
                ?? "Gave up filing a note from \(when): \(reason)"
            appState.recordError(message, source: .capture)
            appState.activity.record(.gaveUp, source: .iMessage, message, path: rescued)
            return rescued != nil
        }

        pendingFailures[key] = pending
        if pending.attempts == 1 {
            appState.recordError(reason, source: .capture)
            appState.activity.record(
                .failed, source: .iMessage,
                "\(Self.titleHint(captured.decodedText)): \(reason). Retrying every minute."
            )
            if let result {
                queueReply { [replier] in
                    await replier.replyForWrite(captured: captured, result: result, settings: settings)
                }
            }
        }
        return false
    }

    /// Last resort after `giveUpAfter`: the capture's text (and where its
    /// attachments were) goes to `<app support>/Failed captures/`, so giving up
    /// on the notes folder never means losing the words.
    private func rescue(_ captured: CapturedMessage) -> URL? {
        do {
            let dir = try appState.supportDirectoryURL()
                .appendingPathComponent("Failed captures", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = FileWriter.baseName(for: captured.event.dateUTC)
            let (url, _) = FileWriter.uniqueDestination(in: dir, baseName: base)
            let attachmentLines = captured.event.attachments.map { "- \($0.sourcePath)" }
            let body = attachmentLines.isEmpty
                ? captured.decodedText
                : captured.decodedText + "\n\nAttachments (original locations):\n" + attachmentLines.joined(separator: "\n") + "\n"
            try AtomicFile.write(Data(body.utf8), to: url)
            return url
        } catch {
            Self.log.error("rescue failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func attachmentMissing(url: URL, captured: CapturedMessage, failedSourcePaths: [String], source: ActivityEvent.Source) {
        let count = failedSourcePaths.count
        let message = "\(count) \(count == 1 ? "attachment" : "attachments") not downloaded yet for \(Self.noteName(url)). Retrying."
        appState.recordError(message, source: .attachments)
        appState.activity.record(.attachmentMissing, source: source, message, path: url)
        let missing = captured.event.attachments.filter { failedSourcePaths.contains($0.sourcePath) }
        attachmentRetrier?.schedule(noteURL: url, attachments: missing)
    }

    nonisolated static func failureKey(_ event: MessageEvent) -> String {
        event.guid.isEmpty ? "rowid:\(event.rowid)" : event.guid
    }

    nonisolated static func noteName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// A few words of a capture for history lines about notes that never got
    /// a filename (failed or queued).
    nonisolated static func titleHint(_ text: String) -> String {
        let title = TitleDeriver.voiceNoteTitle(from: text)
        return "\"\(title)\""
    }

}
