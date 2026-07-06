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
    private let clock: @Sendable () -> Date

    private var lastFailureAt: [String: Date] = [:]
    private var reportedOversized: Set<String> = []

    init(
        appState: AppState,
        filer: any RelayFiling,
        ledger: RelayFiledLedger,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.filer = filer
        self.ledger = ledger
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

        for candidate in batch.candidates {
            await processCandidate(candidate, folder: folder)
        }
        for orphanURL in batch.orphanAudio {
            await processOrphanAudio(orphanURL, folder: folder)
        }
    }

    private func processCandidate(_ candidate: RelayCandidate, folder: URL) async {
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

        let result = await filer.file(candidate, to: folder)
        switch result.outcome {
        case .success(let url):
            Self.log.info("filed relay note \(url.lastPathComponent, privacy: .public)")
            let audioCopied = candidate.audioURL != nil && result.failedAttachments.isEmpty
            // Record before delete: closes the crash window (see type comment).
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

        let result = await filer.fileOrphanAudio(at: url, to: folder)
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
