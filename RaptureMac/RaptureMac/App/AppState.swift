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

    let settings: SettingsStore
    let state: StateStore
    let integrations: IntegrationsState

    /// Serializes capture writes against an output-folder relocation. See `CaptureGate`.
    let captureGate = CaptureGate()

    /// - Parameter supportDirectory: overrides where settings.json/state.json
    ///   live. Tests pass a temp directory so they never touch the dev
    ///   machine's live container; the app passes nil (app-support container).
    init(supportDirectory: URL? = nil) {
        self.settings = SettingsStore(directory: supportDirectory)
        self.state = StateStore(directory: supportDirectory)
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

        isRelocating = true
        relocationStatus = .inProgress

        await captureGate.withLock {
            do {
                // Run the file moves off the main actor so a large or cross-volume copy
                // doesn't freeze the Settings UI; the gate stays held throughout, so
                // capture writes remain blocked until the move completes.
                try await Task.detached(priority: .userInitiated) {
                    let migrator = OutputFolderMigrator()
                    if let old {
                        try migrator.migrate(from: old, to: new)
                    } else {
                        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
                    }
                }.value
                settings.update { $0.outputFolder = new }
                OutputFolderSidecar.write(new)
                // Opt-in; no-op unless the new folder ended up empty + CLAUDE.md-less.
                if settings.settings.seedScaffold {
                    OutputFolderScaffold.seedIfEligible(folder: new)
                }
                relocationStatus = .idle
                if lastError != nil { clearError() }
            } catch {
                let message = error.localizedDescription
                relocationStatus = .failed(message)
                recordError("Couldn't move notes: \(message)")
            }
        }

        isRelocating = false
    }
}
