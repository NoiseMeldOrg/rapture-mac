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
    private let clock: @Sendable () -> Date

    private var lastFailureAt: [String: Date] = [:]
    private var reportedOversized: Set<String> = []

    init(
        appState: AppState,
        filer: any RelayFiling,
        ledger: RelayFiledLedger,
        triageLedger: TriageLedger,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.filer = filer
        self.ledger = ledger
        self.triageLedger = triageLedger
        self.destinationGuard = destinationGuard
        self.handoff = handoff
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
        for candidate in batch.candidates {
            await processCandidate(candidate, folder: folder, mode: mode)
        }
        for orphanURL in batch.orphanAudio {
            await processOrphanAudio(orphanURL, folder: folder)
        }
    }

    private func processCandidate(_ candidate: RelayCandidate, folder: URL, mode: TriageMode) async {
        let name = candidate.relayFilename

        // Already filed (restart or iCloud re-sync): drain the relay, never re-file.
        if ledger.contains(relayFilename: name) {
            removeRelayFile(candidate.txtURL)
            if let audioURL = candidate.audioURL, ledger.contains(relayFilename: audioURL.lastPathComponent) {
                removeRelayFile(audioURL)
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
            removeRelayFile(candidate.txtURL)
            if audioCopied, let audioURL = candidate.audioURL {
                removeRelayFile(audioURL)
            }
            // A failed audio copy keeps the .m4a in the relay; the orphan path
            // retries it once its txt is gone.
            if let handoff, let relayData {
                // Dates parse relative to the capture's own timestamp (the relay
                // filename stamp), not filing time — an offline backlog that
                // says "tomorrow" means the day after it was dictated.
                let capturedAt = RelayWatcher.parseRelayTimestamp(name) ?? clock()
                _ = await handoff.process(
                    text: String(decoding: relayData, as: UTF8.self),
                    capturedAt: capturedAt
                )
            }
            appState.state.recordSuccess(at: clock())
            lastFailureAt[name] = nil
            if !result.failedAttachments.isEmpty {
                recordRelayError("Audio for \(name) could not be copied yet, it will be retried")
            } else {
                clearRelayError()
            }
        case .failure(let reason):
            Self.log.error("relay filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
            lastFailureAt[name] = clock()
            recordRelayError(reason)
        case .unavailable:
            // The volume vanished between the batch guard and this write: silent
            // defer, no backoff — the relay copy stays and the next scan retries.
            Self.log.debug("relay filing deferred for \(name, privacy: .public): destination offline")
        }
    }

    private func processOrphanAudio(_ url: URL, folder: URL) async {
        let name = url.lastPathComponent

        if ledger.contains(relayFilename: name) {
            removeRelayFile(url)
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
        var preferredDirectory: URL?
        let pairedTxt = RelayWatcher.pairedTxtName(forAudio: name)
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
            removeRelayFile(url)
            lastFailureAt[name] = nil
            // No recordSuccess: the today count counts notes, and the note already
            // counted when its txt filed.
        case .failure(let reason):
            Self.log.error("orphan audio filing failed for \(name, privacy: .public): \(reason, privacy: .public)")
            lastFailureAt[name] = clock()
            recordRelayError(reason)
        case .unavailable:
            Self.log.debug("orphan audio deferred for \(name, privacy: .public): destination offline")
        }
    }

    // MARK: - Helpers

    /// Direct file removal is correct here: the relay is a delivery queue this app
    /// owns draining, not the user's output folder. `FileSafety.removeIfEmpty`
    /// remains the app's only *directory*-delete primitive. A failed delete is
    /// retried on the next scan via the ledger-hit path.
    private func removeRelayFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.log.warning("couldn't remove relay copy \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private func recordRelayError(_ message: String) {
        appState.relayLastError = message
        appState.recordError(message)
    }

    private func clearRelayError() {
        guard appState.relayLastError != nil else { return }
        appState.relayLastError = nil
        if appState.lastError != nil {
            appState.clearError()
        }
    }
}
