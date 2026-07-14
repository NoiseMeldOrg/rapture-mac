import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum PermissionState: Equatable {
        case unknown
        case fullDiskAccessRequired
        case ok
    }

    /// Transient status of an in-flight output-folder relocation. Not persisted.
    enum RelocationStatus: Equatable {
        case idle
        case inProgress
        case failed(String)
    }

    var permissionState: PermissionState = .unknown
    var automationPermissionState: AutomationPermissionState = .unknown
    var lastError: String?
    var lastErrorAt: Date?

    /// True while notes are being moved between folders. The capture pipeline treats this
    /// like `paused` (defers new batches) so writes don't race the move. Transient.
    var isRelocating = false
    var relocationStatus: RelocationStatus = .idle

    /// Transient status of the relay capture source (see `RelayWatcher`). Not persisted.
    var relayStatus: RelayStatus = .off
    /// Last relay filing error. Kept separate from `relayStatus` so a per-tick status
    /// post can never clobber an error the user hasn't seen yet. Transient.
    var relayLastError: String?

    /// Transient status of the triage engine (see `TriageWatcher`/`TriageProcessor`).
    var triageStatus: TriageStatus = .off
    /// Last triage error. Same separation rationale as `relayLastError`. Transient.
    var triageLastError: String?

    /// True while the destination's volume is absent (see `DestinationGuard`).
    /// Maintained by `DestinationMonitor`; UI + flush-trigger signal only — the
    /// write path re-checks the guard synchronously inside the capture gate.
    var destinationOffline = false
    /// Captures waiting for the destination: spool items + pending relay files.
    /// Maintained by `DestinationMonitor`. Transient.
    var queuedCaptureCount = 0
    /// Relay files deferring in the relay folder because the destination volume
    /// is absent. Set by `RelayProcessor`, folded into `queuedCaptureCount`.
    var relayPendingOffline = 0

    /// Last Reminders/Calendar handoff error (create failure or revoked grant).
    /// Rendered in the Settings handoff section only — a handoff failure never
    /// touches the menu-bar error surface, because the note itself filed fine.
    var handoffLastError: String?

    /// Which AI triage engine is active (or why none is). Settings-only surface,
    /// maintained by `AITriageService`. Transient.
    var aiEngineStatus: AIEngineStatus = .off
    /// Last AI triage error. Same rule as `handoffLastError`: Settings only,
    /// never the menu bar — the capture itself filed fine, deterministically.
    var aiLastError: String?

    let settings: SettingsStore
    let state: StateStore
    let integrations: IntegrationsState

    /// The EventKit seam shared by the Settings UI (toggles/pickers) and the
    /// pipeline's `HandoffManager`. Constructing the production client is inert
    /// (no `EKEventStore` until a method runs); tests inject a fake.
    let eventKit: any EventKitClient

    /// The app's one credential seam (the optional Anthropic API key), shared by
    /// the Settings key field and `AITriageService`. Keychain-backed in the app;
    /// tests inject a fake. Construction is inert — no keychain I/O until a
    /// method runs.
    let credentials: any CredentialStore

    /// Serializes capture writes against an output-folder relocation. See `CaptureGate`.
    let captureGate = CaptureGate()

    /// Volume-absence classifier used before relocations. Injectable for tests.
    private let destinationGuard: DestinationGuard

    /// - Parameter supportDirectory: overrides where settings.json/state.json
    ///   live. Tests pass a temp directory so they never touch the dev
    ///   machine's live container; the app passes nil (app-support container).
    init(
        supportDirectory: URL? = nil,
        destinationGuard: DestinationGuard = DestinationGuard(),
        eventKit: (any EventKitClient)? = nil,
        credentials: (any CredentialStore)? = nil
    ) {
        self.settings = SettingsStore(directory: supportDirectory)
        self.state = StateStore(directory: supportDirectory)
        self.destinationGuard = destinationGuard
        self.eventKit = eventKit ?? SystemEventKitClient()
        self.credentials = credentials ?? KeychainStore()
        let loginPath = LoginShellPath.capture()
        let runner = IntegrationRunner(loginPath: loginPath)
        self.integrations = IntegrationsState(
            runner: runner,
            examplesRoot: Bundle.main.examplesURL,
            scriptsRoot: Bundle.main.scriptsURL
        )
        self.lastError = state.state.lastError
    }

    func recordError(_ message: String) {
        lastError = message
        lastErrorAt = Date()
        state.update { $0.lastError = message }
    }

    func clearError() {
        lastError = nil
        lastErrorAt = nil
        state.update { $0.lastError = nil }
    }

    /// The single entry point for changing the output folder. Moves the existing notes tree
    /// to the new location (Dropbox-style), then switches the active folder and updates the
    /// downstream-consumer sidecar. Silent on success; on failure the source is left intact
    /// and the active folder is **not** changed.
    func setOutputFolder(_ newRaw: URL) async {
        let new = OutputFolderMigrator.normalize(newRaw)
        let old = settings.settings.outputFolder.map(OutputFolderMigrator.normalize)

        // No-op when unchanged.
        guard old?.path != new.path else { return }

        // Relocating TO an absent volume must fail up front: the migrator's
        // ensureDirectory would otherwise fabricate a shadow folder on the boot
        // volume (see DestinationGuard).
        guard destinationGuard.check(new) != .volumeAbsent else {
            let message = "The drive for \"\(new.lastPathComponent)\" isn't connected."
            relocationStatus = .failed(message)
            recordError("Couldn't move notes: \(message)")
            return
        }
        // Relocating AWAY FROM an absent volume: nothing can be moved off an
        // unplugged drive. Allowed (the user may need a working destination now),
        // but the stranded notes deserve an honest notice below.
        let oldVolumeAbsent = old.map { destinationGuard.check($0) == .volumeAbsent } ?? false

        isRelocating = true
        relocationStatus = .inProgress

        await captureGate.withLock {
            do {
                // Run the file moves off the main actor so a large or cross-volume copy
                // doesn't freeze the Settings UI; the gate stays held throughout, so
                // capture writes remain blocked until the move completes.
                let report = try await Task.detached(priority: .userInitiated) { () -> OutputFolderMigrator.MigrationReport? in
                    let migrator = OutputFolderMigrator()
                    if let old {
                        return try migrator.migrate(from: old, to: new)
                    } else {
                        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
                        return nil
                    }
                }.value
                settings.update { $0.outputFolder = new }
                // Collision-renamed notes: keep the triage ledger's recorded
                // destinations pointing at the real files.
                if let report, !report.renamedNotes.isEmpty {
                    TriageLedger(stateStore: state).remap(report.renamedNotes)
                }
                OutputFolderSidecar.write(new)
                // Opt-in; no-op unless the new folder ended up empty + CLAUDE.md-less.
                if settings.settings.seedScaffold {
                    OutputFolderScaffold.seedIfEligible(folder: new)
                }
                relocationStatus = .idle
                if oldVolumeAbsent {
                    recordError("Your previous notes are still on the disconnected drive. Reconnect it and switch the folder back to move them.")
                } else if lastError != nil {
                    clearError()
                }
            } catch {
                let message = error.localizedDescription
                relocationStatus = .failed(message)
                recordError("Couldn't move notes: \(message)")
            }
        }

        isRelocating = false
    }
}
