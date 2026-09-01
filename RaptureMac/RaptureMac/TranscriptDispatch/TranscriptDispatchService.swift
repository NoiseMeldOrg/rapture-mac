import Foundation
import OSLog

/// Dispatches enriched YouTube captures to the user's own local Claude Code
/// CLI, which runs the transcript pipeline defined in the agentic repo's
/// AGENTS.md and appends the resulting Google Doc link to the source note.
/// Rapture contains no pipeline logic — it only hands off.
///
/// Strictly best-effort and strictly serial: one session at a time, FIFO, and
/// the capture/enrichment path never waits on it (`captureEnriched` is
/// enqueue-only). Trouble surfaces only via
/// `AppState.transcriptDispatchLastError` (Settings), never the menu bar — the
/// note itself filed and enriched fine. The user's daily cron sweep remains
/// the safety net for anything this misses.
@Observable
@MainActor
final class TranscriptDispatchService: TranscriptDispatching {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "TranscriptDispatchService")

    /// Completion is detected by re-reading the note, so the loop polls faster
    /// than the vault watchdog but still cheaply (a file read at most).
    nonisolated static let pollInterval: TimeInterval = 15
    /// A wedged session is killed after this budget and the entry marked failed.
    nonisolated static let sessionTimeout: TimeInterval = 15 * 60
    /// Single-strike pause after any failure: each dispatch is a
    /// 15-minute-budget subprocess, so a systemically broken `claude` must not
    /// chew through a backlog.
    nonisolated static let failureCooldown: TimeInterval = 10 * 60

    private let appState: AppState
    private let ledger: TranscriptDispatchLedger
    private let launcher: any TranscriptSessionLaunching
    private let agenticRepo: URL
    private let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var cooldownUntil: Date?

    init(
        appState: AppState,
        ledger: TranscriptDispatchLedger,
        launcher: any TranscriptSessionLaunching,
        agenticRepo: URL = TranscriptDispatch.defaultAgenticRepo,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.ledger = ledger
        self.launcher = launcher
        self.agenticRepo = agenticRepo
        self.clock = clock
    }

    func start() {
        ledger.seedIfNeeded(now: clock())
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.reconcile()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    /// Cancels the loop but deliberately leaves an in-flight child alone —
    /// reconciliation resolves its entry honestly on the next launch.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - TranscriptDispatching (called inside the capture gate; never blocks)

    func captureEnriched(fingerprint: String, url: String, noteRelativePath: String) {
        guard appState.settings.settings.autoTranscribeYouTube else { return }
        guard fingerprint.hasPrefix("yt:") else { return }
        // No pipeline repo, no dispatch: the app ships publicly with this
        // toggle on, so machines without the agentic repo must stay silent.
        guard FileManager.default.fileExists(atPath: agenticRepo.path) else { return }

        if let existing = ledger.entry(fingerprint: fingerprint) {
            // A fresh capture of a previously failed video is an implicit
            // retry; point the entry at the newest note. Done/pending/
            // dispatched entries are the idempotency guarantee — no-op.
            if existing.status == .failed {
                ledger.update(fingerprint: fingerprint) {
                    $0.status = .pending
                    $0.lastError = nil
                    $0.noteRelativePath = noteRelativePath
                }
            }
            return
        }
        ledger.append(TranscriptDispatchEntry(
            fingerprint: fingerprint,
            url: url,
            noteRelativePath: noteRelativePath,
            status: .pending,
            createdAt: clock()
        ))
    }

    /// The Settings "Retry failed" button.
    func retryFailed() {
        ledger.retryFailed()
        appState.transcriptDispatchLastError = nil
        cooldownUntil = nil
    }

    // MARK: - Drain loop

    /// One check. Internal (not private) so tests drive it deterministically.
    /// The early return while an entry is `dispatched` IS the one-at-a-time
    /// guarantee.
    func tick() async {
        if let inFlight = ledger.records.first(where: { $0.status == .dispatched }) {
            await resolveInFlight(inFlight)
            return
        }
        if let until = cooldownUntil {
            guard clock() >= until else { return }
            cooldownUntil = nil
        }
        guard appState.settings.settings.autoTranscribeYouTube else { return }
        guard let next = oldestPending() else { return }
        await spawn(next)
    }

    /// Startup pass: at most zero `dispatched` entries may survive into the
    /// loop (the ≤1-in-flight invariant assumes the launcher owns any live
    /// child, and a fresh launcher owns none). Never auto-respawn — a half-run
    /// pipeline retried blind could create a duplicate Google Doc; a visible
    /// failed row with a Retry button is the honest outcome.
    func reconcile() async {
        for entry in ledger.records where entry.status == .dispatched {
            if let text = await noteText(for: entry), TranscriptDispatch.containsTranscriptMarker(text) {
                ledger.update(fingerprint: entry.fingerprint) {
                    $0.status = .done
                    $0.lastError = nil
                }
            } else {
                ledger.update(fingerprint: entry.fingerprint) {
                    $0.status = .failed
                    $0.lastError = "Interrupted by an app restart — retry from Settings."
                }
            }
        }
    }

    private func resolveInFlight(_ entry: TranscriptDispatchEntry) async {
        if let text = await noteText(for: entry), TranscriptDispatch.containsTranscriptMarker(text) {
            launcher.terminate()
            ledger.update(fingerprint: entry.fingerprint) {
                $0.status = .done
                $0.lastError = nil
            }
            appState.transcriptDispatchLastError = nil
            cooldownUntil = nil
            Self.log.info("transcript landed for \(entry.fingerprint, privacy: .public)")
            return
        }
        if !launcher.isRunning() {
            fail(entry, message: launcher.lastFailureDetail() ?? "The session ended without writing a transcript link.")
            return
        }
        if let dispatchedAt = entry.dispatchedAt, clock().timeIntervalSince(dispatchedAt) > Self.sessionTimeout {
            launcher.terminate()
            fail(entry, message: "Timed out after \(Int(Self.sessionTimeout / 60)) minutes.")
        }
        // Otherwise: still working. Wait for the next tick.
    }

    private func spawn(_ entry: TranscriptDispatchEntry) async {
        guard let folder = appState.settings.settings.outputFolder else { return }
        let noteURL = folder.appendingPathComponent(entry.noteRelativePath)
        guard let text = await noteText(at: noteURL) else {
            fail(entry, message: "The note wasn't found — it may have been moved or renamed.")
            return
        }
        // Already carries a transcript link (the cron sweep beat us, or a
        // human added one) → done without spending a session.
        if TranscriptDispatch.containsTranscriptMarker(text) {
            ledger.update(fingerprint: entry.fingerprint) { $0.status = .done }
            return
        }

        // Mark BEFORE launching: a crash between the two leaves a `dispatched`
        // entry that reconciliation flips to a visible `failed` — never two
        // live sessions for one video (at-most-once beats at-least-once here;
        // the retry path is one click).
        ledger.update(fingerprint: entry.fingerprint) {
            $0.status = .dispatched
            $0.dispatchedAt = clock()
            $0.attempts += 1
        }
        let transcriptRelative = TranscriptDispatch.transcriptRelativePath(forNoteRelativePath: entry.noteRelativePath)
        let prompt = TranscriptDispatch.prompt(
            url: entry.url,
            noteAbsolutePath: noteURL.path,
            transcriptAbsolutePath: folder.appendingPathComponent(transcriptRelative).path,
            transcriptLine: TranscriptDispatch.transcriptLine(
                transcriptFilename: (transcriptRelative as NSString).lastPathComponent)
        )
        do {
            try await launcher.launch(prompt: prompt, workingDirectory: agenticRepo)
            Self.log.info("dispatched \(entry.fingerprint, privacy: .public)")
        } catch {
            let message: String
            if let sessionError = error as? TranscriptSessionError, case .spawnFailed(let detail) = sessionError {
                message = detail
            } else {
                message = error.localizedDescription
            }
            fail(entry, message: "Couldn't start the session: \(message)")
        }
    }

    private func fail(_ entry: TranscriptDispatchEntry, message: String) {
        ledger.update(fingerprint: entry.fingerprint) {
            $0.status = .failed
            $0.lastError = message
        }
        appState.transcriptDispatchLastError = "Transcript dispatch failed: \(message)"
        cooldownUntil = clock().addingTimeInterval(Self.failureCooldown)
        Self.log.warning("dispatch failed for \(entry.fingerprint, privacy: .public): \(message, privacy: .public)")
    }

    private func oldestPending() -> TranscriptDispatchEntry? {
        ledger.records
            .filter { $0.status == .pending }
            .min { $0.createdAt < $1.createdAt }
    }

    private func noteText(for entry: TranscriptDispatchEntry) async -> String? {
        guard let folder = appState.settings.settings.outputFolder else { return nil }
        return await noteText(at: folder.appendingPathComponent(entry.noteRelativePath))
    }

    /// Reads must not block the main actor (dataless File-Provider files can
    /// stall until download) — the enrichment/TriageProcessor discipline.
    private func noteText(at url: URL) async -> String? {
        let data = try? await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
        return data.map { String(decoding: $0, as: UTF8.self) }
    }
}
