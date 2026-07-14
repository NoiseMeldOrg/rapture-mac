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
    nonisolated static let recentGuidCapacity = 100

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
    private let selfHandlesProvider: @MainActor () -> Set<String>
    private let selfChatGuidProvider: @MainActor () -> String?
    private let advanceWatermark: @MainActor (Int64) -> Void

    private var isFirstNonemptyBatchSeen = false
    private var wasPausedLastBatch = false
    private var recentGuids: [String] = []

    init(
        appState: AppState,
        writer: FileWriting,
        replier: Replier,
        echoGuard: EchoGuard,
        contentDedupCache: ContentDedupCache,
        spool: SpoolStore,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        selfHandlesProvider: @escaping @MainActor () -> Set<String>,
        selfChatGuidProvider: @escaping @MainActor () -> String?,
        advanceWatermark: @escaping @MainActor (Int64) -> Void
    ) {
        self.appState = appState
        self.writer = writer
        self.replier = replier
        self.echoGuard = echoGuard
        self.contentDedupCache = contentDedupCache
        self.spool = spool
        self.destinationGuard = destinationGuard
        self.handoff = handoff
        self.selfHandlesProvider = selfHandlesProvider
        self.selfChatGuidProvider = selfChatGuidProvider
        self.advanceWatermark = advanceWatermark
    }

    @discardableResult
    func process(batch: [MessageEvent]) async -> BatchOutcome {
        // Hold the capture gate for the whole batch so an output-folder relocation can't
        // run while this batch is mid-write, and so the folder URL captured below can't go
        // stale mid-batch. The relocator acquires the same gate before moving files.
        await appState.captureGate.withLock {
            await processLocked(batch: batch)
        }
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
        let handles = selfHandlesProvider()

        for event in batch {
            // GUID-based dedup: iCloud sync delivers each logical message to chat.db
            // once per paired device, each with a different ROWID but the same
            // `message.guid`. Without this check, one Siri-dictated note becomes
            // 3–4 captured files.
            let dedup = Self.dedupCheck(
                guid: event.guid,
                recent: recentGuids,
                capacity: Self.recentGuidCapacity
            )
            if dedup.isDuplicate {
                Self.log.debug("dedup-suppressed rowid=\(event.rowid) guid=\(event.guid, privacy: .public)")
                advanceWatermark(event.rowid)
                outcome.droppedCount += 1
                continue
            }
            recentGuids = dedup.updatedRecent

            let decision = MessageFilter.decide(
                event: event,
                selfHandles: handles,
                settings: settings,
                isCatchup: isCatchup
            )

            switch decision {
            case .drop(let reason):
                Self.log.debug("dropped rowid=\(event.rowid) reason=\(reason.rawValue, privacy: .public)")
                advanceWatermark(event.rowid)
                outcome.droppedCount += 1

            case .capture(let captured):
                if let chatGuid = captured.event.chatGuid,
                   echoGuard.consume(chatGuid: chatGuid, text: captured.decodedText) {
                    Self.log.debug("echo-suppressed rowid=\(event.rowid)")
                    advanceWatermark(event.rowid)
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
                    advanceWatermark(event.rowid)
                    outcome.droppedCount += 1
                    continue
                }

                guard let folder = settings.outputFolder else {
                    appState.recordError("No output folder configured")
                    outcome.failureCount += 1
                    continue
                }

                // Spool instead of writing when the destination's volume is absent
                // — or when older captures are already queued: writing ahead of the
                // spool would break the flush's original-capture-order guarantee.
                // The guard runs synchronously inside the capture gate, so it can't
                // race the monitor's flush.
                if destinationGuard.check(folder) == .volumeAbsent || !spool.isEmpty {
                    await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, outcome: &outcome)
                    continue
                }

                let result = await writer.write(captured, to: folder, mode: settings.triageMode)
                switch result.outcome {
                case .success(let url):
                    Self.log.info("wrote \(url.lastPathComponent, privacy: .public) (rowid=\(event.rowid))")
                    if !result.failedAttachments.isEmpty {
                        appState.recordError("Some attachments missing for \(url.lastPathComponent)")
                    } else if appState.lastError != nil {
                        appState.clearError()
                    }
                    appState.state.recordSuccess(at: Date())
                    advanceWatermark(event.rowid)
                    outcome.successCount += 1
                    contentDedupCache.track(
                        handle: handleForDedup,
                        text: captured.decodedText,
                        attachmentCount: captured.event.attachments.count
                    )
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
                    await replier.replyForWrite(
                        captured: captured, result: result, settings: settings, handoff: handoffOutcome
                    )
                case .failure(let reason):
                    if destinationGuard.check(folder) == .volumeAbsent {
                        // The unplug raced the write: the failure IS the absence.
                        await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, outcome: &outcome)
                        continue
                    }
                    Self.log.error("write failed rowid=\(event.rowid): \(reason, privacy: .public)")
                    appState.recordError(reason)
                    outcome.failureCount += 1
                    await replier.replyForWrite(captured: captured, result: result, settings: settings)
                case .unavailable:
                    // The writer's internal guard fired (defense in depth).
                    await spoolCapture(captured, handleForDedup: handleForDedup, settings: settings, outcome: &outcome)
                }
            }
        }

        if isCatchup {
            await replier.sendCatchupSummary(
                successCount: outcome.successCount,
                failureCount: outcome.failureCount,
                selfChatGuid: selfChatGuidProvider(),
                replyMode: settings.replyMode
            )
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
        outcome: inout BatchOutcome
    ) async {
        do {
            let item = try await spool.add(
                text: captured.decodedText,
                capturedAt: captured.event.dateUTC,
                source: .raptureMac,
                attachments: captured.event.attachments
            )
            Self.log.info("spooled rowid=\(captured.event.rowid) as \(item.name, privacy: .public) (destination offline)")
            appState.state.recordSuccess(at: Date())
            advanceWatermark(captured.event.rowid)
            outcome.successCount += 1
            contentDedupCache.track(
                handle: handleForDedup,
                text: captured.decodedText,
                attachmentCount: captured.event.attachments.count
            )
            await replier.replyForSpooled(captured: captured, settings: settings)
        } catch {
            // Spool write failed (app-support container unwritable — should not
            // happen). Existing failure semantics: error surfaced, watermark held,
            // the row replays next poll.
            let reason = "Couldn't queue capture: \(error.localizedDescription)"
            Self.log.error("\(reason, privacy: .public)")
            appState.recordError(reason)
            outcome.failureCount += 1
        }
    }

}
