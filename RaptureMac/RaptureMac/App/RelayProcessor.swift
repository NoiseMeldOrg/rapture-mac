import Foundation
import OSLog

/// Consumes `RelayWatcher` batches and drives filing: dedup via the ledger, filing
/// via `RelayFiler`, relay-copy deletion, today-count accounting, and error
/// surfacing. Sibling of `BatchProcessor` with the same locking discipline: the
/// whole batch runs under `appState.captureGate` so filing can't race an
/// output-folder relocation, and pause/relocation defer the batch entirely.
///
/// Deferral is free here: every scan re-emits still-pending relay files, so
/// "defer" is simply "return"; the next scan re-delivers the same items.
///
/// Per-item flow is file → record ledger entry (persisted) → delete relay copy.
/// A crash between file and record re-files on restart (rare `-1` duplicate, never
/// data loss); a crash between record and delete resumes as delete-only.
@MainActor
final class RelayProcessor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "RelayProcessor")

    /// A persistent failure (e.g. unwritable output folder) must not re-file and
    /// re-report every poll tick; each failed name waits this long before retrying.
    nonisolated static let failureRetryBackoff: TimeInterval = 60

    /// Sanity cap. A relay note is dictated or typed text; anything this large is
    /// not a note. Reported once and left in the relay for the user, never deleted.
    nonisolated static let maxTxtBytes = 10 * 1024 * 1024

    private let appState: AppState
    private let filer: any RelayFiling
    private let ledger: RelayFiledLedger
    private let triageLedger: TriageLedger
    private let destinationGuard: DestinationGuard
    /// Reminders/Calendar handoff, fired once per freshly-filed note. Silent —
    /// relay captures have no reply path (PRD). Optional so existing tests are
    /// unchanged.
    private let handoff: (any HandoffProcessing)?
    /// Link enrichment (M5), enqueued once per freshly-filed link note (never
    /// on ledger-hit ghost drains).
    private let enrichment: (any LinkEnriching)?
    /// Meeting parts (iOS meeting mode) bypass `filer` entirely: one note per
    /// meeting id, no AI, no handoffs, no enrichment. See `MeetingFiler`.
    private let meetingFiler: MeetingFiler
    private let meetingLedger: MeetingLedger
    private let clock: @Sendable () -> Date

    private var lastFailureAt: [String: Date] = [:]
    /// Failed attempts per relay name, shown in the error so a file that
    /// fails every minute doesn't look like a one-off.
    private var failureCounts: [String: Int] = [:]
    private var reportedOversized: Set<String> = []

    init(
        appState: AppState,
        filer: any RelayFiling,
        ledger: RelayFiledLedger,
        triageLedger: TriageLedger,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        enrichment: (any LinkEnriching)? = nil,
        meetingFiler: MeetingFiler? = nil,
        meetingLedger: MeetingLedger? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.filer = filer
        self.ledger = ledger
        self.triageLedger = triageLedger
        self.destinationGuard = destinationGuard
        self.handoff = handoff
        self.enrichment = enrichment
        self.meetingFiler = meetingFiler ?? MeetingFiler(destinationGuard: destinationGuard)
        self.meetingLedger = meetingLedger ?? MeetingLedger(stateStore: appState.state, clock: clock)
        self.clock = clock
    }

    /// Pure backoff decision, testable without a processor.
    nonisolated static func shouldAttempt(name: String, lastFailureAt: [String: Date], now: Date) -> Bool {
        guard let last = lastFailureAt[name] else { return true }
        return now.timeIntervalSince(last) >= failureRetryBackoff
    }

    func process(batch: RelayScanBatch) async {
        await appState.captureGate.withLock {
            await self.processLocked(batch)
        }
    }

    private func processLocked(_ batch: RelayScanBatch) async {
        let settings = appState.settings.settings
        // Same deferral semantics as BatchProcessor.policy: paused or relocating
        // means touch nothing; the next scan re-delivers.
        guard !settings.paused, !appState.isRelocating else { return }
        // Defensive: the watcher stops emitting when disabled, but a batch may
        // already be in flight when the toggle flips.
        guard settings.relayEnabled else { return }
        guard let folder = settings.outputFolder else {
            recordRelayError("No output folder configured")
            return
        }

        // Destination volume absent: the relay folder IS the queue — files stay
        // put, no error, no backoff. Surfaced via the destination-offline status
        // (the pending count folds into the menu bar's queued number).
        guard destinationGuard.check(folder) != .volumeAbsent else {
            appState.relayPendingOffline = batch.candidates.count + batch.orphanAudio.count
            return
        }
        if appState.relayPendingOffline != 0 {
            appState.relayPendingOffline = 0
        }

        let mode = settings.triageMode
        let peeked = batch.candidates.map { ($0, MeetingMarker.peek(fileAt: $0.txtURL)) }
        for (candidate, meeting) in Self.meetingOrdered(peeked, modifiedAt: Self.modificationDate(of:)) {
            if let meeting {
                await processMeeting(candidate, header: meeting, folder: folder, mode: mode)
            } else {
                await processCandidate(candidate, folder: folder, mode: mode)
            }
        }
        for orphanURL in batch.orphanAudio {
            await processOrphanAudio(orphanURL, folder: folder)
        }
    }

    private func processCandidate(_ candidate: RelayCandidate, folder: URL, mode: TriageMode) async {
        let name = candidate.relayFilename

        // Already filed (restart or iCloud re-sync): drain the relay, never re-file.
        if ledger.contains(relayFilename: name) {
            await removeRelayFile(candidate.txtURL)
            if let audioURL = candidate.audioURL, ledger.contains(relayFilename: audioURL.lastPathComponent) {
                await removeRelayFile(audioURL)
            }
            return
        }

        guard Self.shouldAttempt(name: name, lastFailureAt: lastFailureAt, now: clock()) else { return }

        if let size = fileSize(of: candidate.txtURL), size > Self.maxTxtBytes {
            if !reportedOversized.contains(name) {
                reportedOversized.insert(name)
                recordRelayError("Relay note \(name) is too large to file automatically")
            }
            return
        }

        // The file may have vanished between scan and processing (e.g. another
        // device withdrew it); the next scan reflects reality.
        guard FileManager.default.fileExists(atPath: candidate.txtURL.path) else { return }

        let result = await filer.file(candidate, to: folder, mode: mode)
        switch result.outcome {
        case .success(let url):
            Self.log.info("filed relay note \(url.lastPathComponent, privacy: .public)")
            appState.activity.record(.filed, source: .iPhoneApp, url.deletingPathExtension().lastPathComponent, path: url)
            let audioCopied = candidate.audioURL != nil && result.failedAttachments.isEmpty
            // One read serves both the triage-ledger hash and the handoff text;
            // the relay copy still exists here (deleted below).
            let relayData = (handoff != nil || mode == .full) ? try? Data(contentsOf: candidate.txtURL) : nil
            // Record before delete: closes the crash window (see type comment).
            if mode == .full {
                // The triage entry's mdRelativePath is what lets a late-arriving
                // orphan audio land next to this note.
                let hash = relayData.map(TriageLedger.hash(of:)) ?? ""
                triageLedger.record(
                    sourceFilename: name,
                    contentHash: hash,
                    mdRelativePath: CaptureContract.relativePath(of: url, in: folder)
                )
            }
            ledger.record(relayFilename: name)
            if audioCopied, let audioURL = candidate.audioURL {
                ledger.record(relayFilename: audioURL.lastPathComponent)
            }
            await removeRelayFile(candidate.txtURL)
            if audioCopied, let audioURL = candidate.audioURL {
                await removeRelayFile(audioURL)
            }
            // A failed audio copy keeps the .m4a in the relay; the orphan path
            // retries it once its txt is gone.
            // Enrichment after ledger + relay-copy cleanup (M5): enqueue only.
            if let enrichment, let echo = result.link {
                enrichment.noteFiled(noteURL: url, in: folder, echo: echo)
            }
            if let handoff, let relayData {
                // Dates parse relative to the capture's own timestamp (the relay
                // filename stamp), not filing time — an offline backlog that
                // says "tomorrow" means the day after it was dictated.
                let capturedAt = RelayWatcher.parseRelayTimestamp(name) ?? clock()
                _ = await handoff.process(
                    text: String(decoding: relayData, as: UTF8.self),
                    capturedAt: capturedAt,
                    ai: result.ai
                )
            }
            appState.state.recordSuccess(at: clock())
            markSucceeded(name)
            if !result.failedAttachments.isEmpty {
                recordRelayError("Audio for \(name) could not be copied yet, it will be retried")
            } else {
                clearRelayError()
            }
        case .failure(let reason):
            Self.log.error("relay filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
            fail(name, reason)
        case .unavailable:
            // The volume vanished between the batch guard and this write: silent
            // defer, no backoff — the relay copy stays and the next scan retries.
            Self.log.debug("relay filing deferred for \(name, privacy: .public): destination offline")
        }
    }

    private func processOrphanAudio(_ url: URL, folder: URL) async {
        let name = url.lastPathComponent

        if ledger.contains(relayFilename: name) {
            await removeRelayFile(url)
            return
        }
        guard Self.shouldAttempt(name: name, lastFailureAt: lastFailureAt, now: clock()) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // When the paired note was triage-filed, its ledger entry records where it
        // landed; the audio then goes into that note's own attachment folder instead
        // of a disconnected root folder. Looked up regardless of the current mode —
        // the note may have filed before a mode flip. Only honored while the note
        // still exists: audio for a note the user deleted must not resurrect its
        // folder, and falls back to the legacy root placement instead.
        let pairedTxt = RelayWatcher.pairedTxtName(forAudio: name)

        // Audio of a meeting's transcript part joins the meeting note, wherever
        // later summaries renamed or moved it, and the note's footer lists it.
        if let meeting = meetingLedger.entry(relayFilename: pairedTxt),
           let note = MeetingFiler.locateNote(meetingId: meeting.meetingId, recordedPath: meeting.noteRelativePath, in: folder) {
            let result = await meetingFiler.attachAudio(url, toNote: note, in: folder)
            switch result.outcome {
            case .success:
                Self.log.info("filed late meeting audio into \(note.lastPathComponent, privacy: .public)")
                var updated = meeting
                updated.noteRelativePath = CaptureContract.relativePath(of: note, in: folder)
                updated.noteHash = MeetingFiler.fileHash(note)
                meetingLedger.upsert(updated)
                ledger.record(relayFilename: name)
                await removeRelayFile(url)
                markSucceeded(name)
            case .failure(let reason):
                Self.log.error("meeting audio filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
                fail(name, reason)
            case .unavailable:
                Self.log.debug("meeting audio deferred for \(name, privacy: .public): destination offline")
            }
            return
        }

        var preferredDirectory: URL?
        if let entry = triageLedger.entry(sourceFilename: pairedTxt) {
            let noteURL = folder.appendingPathComponent(entry.mdRelativePath)
            if FileManager.default.fileExists(atPath: noteURL.path) {
                preferredDirectory = noteURL.deletingPathExtension()
            }
        }

        let result = await filer.fileOrphanAudio(at: url, to: folder, preferredDirectory: preferredDirectory)
        switch result.outcome {
        case .success(let destination):
            Self.log.info("filed orphan relay audio into \(destination.deletingLastPathComponent().lastPathComponent, privacy: .public)/")
            ledger.record(relayFilename: name)
            await removeRelayFile(url)
            markSucceeded(name)
            // No recordSuccess: the today count counts notes, and the note already
            // counted when its txt filed.
        case .failure(let reason):
            Self.log.error("orphan audio filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
            fail(name, reason)
        case .unavailable:
            Self.log.debug("orphan audio deferred for \(name, privacy: .public): destination offline")
        }
    }

    // MARK: - Meetings

    /// Batch order for meeting parts: summaries first (oldest file first, so
    /// the newest summary is applied last and wins), then everything else in
    /// scan order. A summary already waiting in the relay therefore files
    /// before its transcript, and the transcript then drains into it instead
    /// of filing first and being replaced a moment later.
    nonisolated static func meetingOrdered(
        _ items: [(RelayCandidate, MeetingMarker.Header?)],
        modifiedAt: (URL) -> Date?
    ) -> [(RelayCandidate, MeetingMarker.Header?)] {
        let summaries = items.enumerated()
            .filter { $0.element.1?.part == .summary }
            .sorted { lhs, rhs in
                let l = modifiedAt(lhs.element.0.txtURL) ?? .distantPast
                let r = modifiedAt(rhs.element.0.txtURL) ?? .distantPast
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
        let rest = items.filter { $0.1?.part != .summary }
        return summaries + rest
    }

    /// Files one meeting relay part. Identity is the meeting id, never the
    /// relay filename, so the name-based `ledger` is not consulted up front: a
    /// re-made summary may reuse an old relay name and must still apply.
    ///
    /// - transcript, meeting unknown: files a new meeting note.
    /// - transcript, meeting known: drained, never filed (its audio still
    ///   joins the note).
    /// - summary, bytes not applied before: files a new note, or rewrites and
    ///   renames the existing one.
    /// - summary, bytes already applied: an iCloud re-sync; drained, so an old
    ///   copy can never roll the note back.
    private func processMeeting(_ candidate: RelayCandidate, header: MeetingMarker.Header, folder: URL, mode: TriageMode) async {
        let name = candidate.relayFilename
        guard Self.shouldAttempt(name: name, lastFailureAt: lastFailureAt, now: clock()) else { return }

        if let size = fileSize(of: candidate.txtURL), size > Self.maxTxtBytes {
            if !reportedOversized.contains(name) {
                reportedOversized.insert(name)
                recordRelayError("Relay note \(name) is too large to file automatically")
            }
            return
        }
        guard FileManager.default.fileExists(atPath: candidate.txtURL.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: candidate.txtURL)
        } catch {
            fail(name, "Couldn't read \(name): \(error.localizedDescription)")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        // The file changed under us since the peek; the next scan re-derives.
        guard let meeting = MeetingMarker.parse(text), meeting.header == header else { return }

        let id = header.meetingId
        let entry = meetingLedger.entry(meetingId: id)
        let existingNote = MeetingFiler.locateNote(meetingId: id, recordedPath: entry?.noteRelativePath, in: folder)
        let hash = MeetingLedger.hash(of: data)

        let drain: Bool
        switch header.part {
        case .transcript:
            drain = entry != nil || existingNote != nil
        case .summary:
            drain = entry?.appliedSummaryHashes.contains(hash) ?? false
        }

        if drain {
            var audioAttached = false
            if let note = existingNote, let audioURL = candidate.audioURL {
                let result = await meetingFiler.attachAudio(audioURL, toNote: note, in: folder)
                switch result.outcome {
                case .success:
                    audioAttached = true
                case .unavailable:
                    return
                case .failure(let reason):
                    // The .m4a stays in the relay; the orphan path retries it.
                    Self.log.error("meeting audio attach failed for \(name, privacy: .public): \(reason, privacy: .public)")
                }
            }
            var updated = entry ?? MeetingEntry(
                meetingId: id, noteRelativePath: "", part: header.part,
                relayFilenames: [], appliedSummaryHashes: [], updatedAt: clock())
            if let note = existingNote {
                updated.noteRelativePath = CaptureContract.relativePath(of: note, in: folder)
                if audioAttached { updated.noteHash = MeetingFiler.fileHash(note) }
            }
            if !updated.relayFilenames.contains(name) { updated.relayFilenames.append(name) }
            meetingLedger.upsert(updated)
            ledger.record(relayFilename: name)
            if audioAttached, let audioURL = candidate.audioURL {
                ledger.record(relayFilename: audioURL.lastPathComponent)
            }
            await removeRelayFile(candidate.txtURL)
            if audioAttached, let audioURL = candidate.audioURL {
                await removeRelayFile(audioURL)
            }
            markSucceeded(name)
            Self.log.info("drained meeting \(header.part.rawValue, privacy: .public) \(name, privacy: .public): already filed")
            return
        }

        let capturedAt = RelayWatcher.parseRelayTimestamp(name) ?? clock()
        let keepEdits = Self.userEdited(existingNote, entry: entry)
        let result = await meetingFiler.write(
            meeting,
            rawText: text,
            relayBaseName: candidate.baseName,
            capturedAt: capturedAt,
            existingNote: existingNote,
            audioURL: candidate.audioURL,
            mode: mode,
            to: folder,
            keepUserEdits: keepEdits
        )
        switch result.outcome {
        case .success(let url):
            Self.log.info("\(existingNote == nil ? "filed" : "replaced", privacy: .public) meeting note \(url.lastPathComponent, privacy: .public)")
            appState.activity.record(
                existingNote == nil ? .meetingFiled : .meetingUpdated, source: .iPhoneApp,
                existingNote == nil
                    ? "\(url.deletingPathExtension().lastPathComponent) (meeting \(header.part.rawValue))"
                    : "\(url.deletingPathExtension().lastPathComponent) (meeting summary replaced the earlier text)",
                path: url
            )
            if keepEdits {
                appState.activity.record(
                    .warning, source: .iPhoneApp,
                    "You had edited \(url.deletingPathExtension().lastPathComponent). Your version is kept next to it as \"Your edits before the summary\".",
                    path: url)
            }
            let audioCopied = candidate.audioURL != nil && result.failedAttachments.isEmpty
            var updated = entry ?? MeetingEntry(
                meetingId: id, noteRelativePath: "", part: header.part,
                relayFilenames: [], appliedSummaryHashes: [], updatedAt: clock())
            updated.noteRelativePath = CaptureContract.relativePath(of: url, in: folder)
            updated.noteHash = MeetingFiler.fileHash(url)
            updated.part = header.part
            if !updated.relayFilenames.contains(name) { updated.relayFilenames.append(name) }
            if header.part == .summary {
                updated.appliedSummaryHashes.removeAll { $0 == hash }
                updated.appliedSummaryHashes.append(hash)
            }
            // Record before delete: same crash-window rule as ordinary notes.
            meetingLedger.upsert(updated)
            ledger.record(relayFilename: name)
            if audioCopied, let audioURL = candidate.audioURL {
                ledger.record(relayFilename: audioURL.lastPathComponent)
            }
            await removeRelayFile(candidate.txtURL)
            if audioCopied, let audioURL = candidate.audioURL {
                await removeRelayFile(audioURL)
            }
            // A replaced meeting is not a new note; only a first filing counts.
            if existingNote == nil {
                appState.state.recordSuccess(at: clock())
            }
            markSucceeded(name)
            if !result.failedAttachments.isEmpty {
                recordRelayError("Audio for \(name) could not be copied yet, it will be retried")
            } else {
                clearRelayError()
            }
        case .failure(let reason):
            Self.log.error("meeting filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
            fail(name, reason)
        case .unavailable:
            Self.log.debug("meeting filing deferred for \(name, privacy: .public): destination offline")
        }
    }

    /// True when the meeting note on disk differs from what the app last
    /// wrote: the user edited it. Unknown (no hash recorded) counts as not
    /// edited, so pre-1.0.126 meetings keep the old replace behavior.
    private static func userEdited(_ note: URL?, entry: MeetingEntry?) -> Bool {
        guard let note, let recorded = entry?.noteHash else { return false }
        return MeetingFiler.fileHash(note) != recorded
    }

    // MARK: - Helpers

    /// Relay copies live in an iCloud container, so removal goes through
    /// `FileSafety.coordinatedRemoveFile` — an uncoordinated delete raced the
    /// file provider right after wake-time materialization and failed
    /// transiently (observed 2026-07-23). Detached because the coordination
    /// wait must not block the main actor; awaited so a batch finishes its
    /// cleanup before returning. The relay is a delivery queue this app owns
    /// draining, not the user's output folder; `FileSafety.removeIfEmpty`
    /// remains the app's only *directory*-delete primitive. A failed delete is
    /// retried on the next scan via the ledger-hit path.
    private func removeRelayFile(_ url: URL) async {
        let outcome = await Task.detached(priority: .utility) {
            FileSafety.coordinatedRemoveFile(at: url)
        }.value
        if case .failed(let reason) = outcome {
            Self.log.warning("couldn't remove relay copy \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        }
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private func fail(_ name: String, _ reason: String) {
        lastFailureAt[name] = clock()
        let attempts = (failureCounts[name] ?? 0) + 1
        failureCounts[name] = attempts
        if attempts == 1 {
            appState.activity.record(.failed, source: .iPhoneApp, "\(Self.displayName(name)): \(reason). Retrying every minute.")
        }
        recordRelayError(attempts == 1 ? reason : "\(reason) (tried \(attempts) times)")
    }

    private func markSucceeded(_ name: String) {
        lastFailureAt[name] = nil
        failureCounts[name] = nil
    }

    /// A relay filename without its timestamp and extension: the iPhone title.
    nonisolated static func displayName(_ relayFilename: String) -> String {
        let base = (relayFilename as NSString).deletingPathExtension
        return TitleDeriver.relayTitle(fromBaseName: base) ?? base
    }

    private func recordRelayError(_ message: String) {
        appState.relayLastError = message
        appState.recordError(message, source: .relay)
    }

    private func clearRelayError() {
        appState.clearError(source: .relay)
        guard appState.relayLastError != nil else { return }
        appState.relayLastError = nil
    }
}
