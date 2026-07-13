import Foundation
import OSLog

/// Polls the configured destination's availability (the house poll-until-
/// precondition idiom, like the FDA retry loop) and drains the internal spool
/// when the volume returns.
///
/// The monitor's `AppState` flags are UI + flush-trigger signals only: the write
/// path re-checks `DestinationGuard` synchronously inside the capture gate, so a
/// stale tick can never mis-route a capture.
///
/// The flush is FIFO-strict: items file in seq (capture) order and a failing
/// head item stops the drain (surfaced, retried after backoff) rather than
/// letting younger captures skip ahead — "flush in original capture order" and
/// "never drop" both hold.
@MainActor
final class DestinationMonitor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "DestinationMonitor")

    nonisolated static let pollInterval: TimeInterval = 2

    /// A persistently failing flush (e.g. destination full) must not re-report
    /// every tick; same backoff convention as the relay/triage processors.
    nonisolated static let flushRetryBackoff: TimeInterval = 60

    private let appState: AppState
    private let spool: SpoolStore
    private let flusher: any SpoolFiling
    private let ledger: SpoolFiledLedger
    private let destinationGuard: DestinationGuard
    /// Reminders/Calendar handoff: a capture spooled offline hands off HERE, at
    /// flush success — the only seam where it durably files. The crash-resume
    /// ledger-hit path never re-fires; the HandoffLedger fingerprint is the
    /// second guard for the file→record crash window. Silent (the queued reply
    /// already went out at spool time).
    private let handoff: (any HandoffProcessing)?
    private let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var lastFlushFailureAt: Date?

    init(
        appState: AppState,
        spool: SpoolStore,
        flusher: any SpoolFiling,
        ledger: SpoolFiledLedger,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.spool = spool
        self.flusher = flusher
        self.ledger = ledger
        self.destinationGuard = destinationGuard
        self.handoff = handoff
        self.clock = clock
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll step. Internal (not private) so tests drive it deterministically.
    func tick() async {
        guard let folder = appState.settings.settings.outputFolder else {
            appState.destinationOffline = false
            appState.queuedCaptureCount = spool.count
            return
        }

        let check = destinationGuard.check(folder)
        let wasOffline = appState.destinationOffline
        appState.destinationOffline = (check == .volumeAbsent)
        appState.queuedCaptureCount = spool.count + appState.relayPendingOffline
        if appState.destinationOffline != wasOffline {
            Self.log.info("destination \(self.appState.destinationOffline ? "offline" : "online", privacy: .public), \(self.appState.queuedCaptureCount) queued")
        }

        guard check != .volumeAbsent, !spool.isEmpty else { return }
        let settings = appState.settings.settings
        guard !settings.paused, !appState.isRelocating else { return }
        if let last = lastFlushFailureAt, clock().timeIntervalSince(last) < Self.flushRetryBackoff { return }

        await flush()
    }

    private func flush() async {
        await appState.captureGate.withLock {
            // Re-read inside the lock: a relocation may have just switched folders
            // or the volume may have vanished again while we waited for the gate.
            let settings = appState.settings.settings
            guard !settings.paused, !appState.isRelocating,
                  let folder = settings.outputFolder,
                  destinationGuard.check(folder) != .volumeAbsent
            else { return }

            for item in spool.items() {
                // Crash resume: filed before a crash but never removed — drain only.
                if ledger.contains(itemName: item.name) {
                    spool.remove(item)
                    continue
                }

                let result = await flusher.file(item, to: folder, mode: settings.triageMode)
                switch result.outcome {
                case .success(let url):
                    // Record before remove: closes the crash window (see ledger).
                    ledger.record(itemName: item.name)
                    // Read the capture text before the item directory is removed.
                    let handoffText: String? = handoff != nil
                        ? (try? Data(contentsOf: item.captureTextURL)).map { String(decoding: $0, as: UTF8.self) }
                        : nil
                    spool.remove(item)
                    lastFlushFailureAt = nil
                    if !result.failedAttachments.isEmpty {
                        appState.recordError("Some attachments missing for \(url.lastPathComponent)")
                    }
                    if let handoff, let handoffText {
                        // capturedAt comes verbatim from the item's metadata —
                        // possibly days old; dates anchor to it, and the manager
                        // skips events whose start has already passed.
                        _ = await handoff.process(text: handoffText, capturedAt: item.metadata.capturedAt)
                    }
                    // No recordSuccess: the capture counted at spool time.
                    Self.log.info("flushed \(item.name, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
                case .unavailable:
                    // Unplugged mid-flush: everything left stays queued, in order.
                    Self.log.info("flush interrupted: destination offline again")
                    return
                case .failure(let reason):
                    // FIFO-strict: never skip ahead of a failing item.
                    appState.recordError("Couldn't file queued capture: \(reason)")
                    lastFlushFailureAt = clock()
                    return
                }
            }

            appState.queuedCaptureCount = spool.count + appState.relayPendingOffline
        }
    }
}
