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
    /// Unresolved errors, one per source (see `ErrorSource`). Mirrored to
    /// state.json so they survive a relaunch with their real timestamps.
    private(set) var errors: [ErrorRecord] = []

    /// The newest unresolved error: what the menu bar shows.
    var newestError: ErrorRecord? { errors.max { $0.at < $1.at } }
    var lastError: String? { newestError?.message }
    var lastErrorAt: Date? { newestError?.at }

    /// Which Settings tab is showing. Transient; lets the menu open a tab.
    var settingsTab: SettingsTab = .general

    /// Local, human-readable history of what the app did (see `ActivityLog`).
    let activity: ActivityLog

    /// True while notes are being moved between folders. The capture pipeline treats this
    /// like `paused` (defers new batches) so writes don't race the move. Transient.
    var isRelocating = false
    var relocationStatus: RelocationStatus = .idle

    /// Transient status of the relay capture source (see `RelayWatcher`). Not persisted.
    var relayStatus: RelayStatus = .off
    /// Last relay filing error. Kept separate from `relayStatus` so a per-tick status
    /// post can never clobber an error the user hasn't seen yet. Transient.
    var relayLastError: String?
    /// When the oldest relay item still waiting for iCloud to download was
    /// first seen; nil when nothing is waiting. Transient.
    var relayWaitingSince: Date?

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

    /// Backup health of the notes folder's git repo (see `VaultBackup/`).
    /// Maintained by `BackupHealthMonitor`; drives the Settings status line
    /// (always) and — when `vaultBackupWarningsEnabled` — the menu-bar warning.
    /// Read-only, no network. Transient.
    var backupHealth: BackupHealth = .unknown

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
    /// Last link-enrichment give-up. Same rule again: Settings only, never the
    /// menu bar — the link note filed fine and is complete without enrichment.
    var enrichmentLastError: String?
    /// Last transcript-dispatch failure (see `TranscriptDispatch/`). Same rule
    /// again: Settings only, never the menu bar — the note filed and enriched
    /// fine; only the external pipeline handoff misfired.
    var transcriptDispatchLastError: String?

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

    /// The login-shell PATH captured once at launch (see `LoginShellPath`).
    /// Shared by `IntegrationRunner` and `ClaudeProcessSessionLauncher` so
    /// spawned tools resolve from `/opt/homebrew/bin` etc.
    let loginPath: String

    /// Where settings.json/state.json/activity.jsonl live; nil = the app-support container.
    private let supportDirectory: URL?

    /// The support directory as a real URL (created if needed).
    func supportDirectoryURL() throws -> URL {
        if let supportDirectory {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            return supportDirectory
        }
        return try AppSupportDirectory.url()
    }

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
        self.supportDirectory = supportDirectory
        self.settings = SettingsStore(directory: supportDirectory)
        self.state = StateStore(directory: supportDirectory)
        self.activity = ActivityLog(directory: supportDirectory)
        self.destinationGuard = destinationGuard
        self.eventKit = eventKit ?? SystemEventKitClient()
        self.credentials = credentials ?? KeychainStore()
        let loginPath = LoginShellPath.capture()
        self.loginPath = loginPath
        let runner = IntegrationRunner(loginPath: loginPath)
        self.integrations = IntegrationsState(
            runner: runner,
            examplesRoot: Bundle.main.examplesURL,
            scriptsRoot: Bundle.main.scriptsURL
        )
        self.errors = state.state.errorRecords
    }

    /// Records (or replaces) the error for `source`. Other sources' errors stay.
    func recordError(_ message: String, source: ErrorSource = .capture, at date: Date = Date()) {
        errors.removeAll { $0.source == source }
        errors.append(ErrorRecord(source: source, message: message, at: date))
        persistErrors()
    }

    /// Clears only `source`'s error: a success in one part of the app says
    /// nothing about another part.
    func clearError(source: ErrorSource) {
        guard errors.contains(where: { $0.source == source }) else { return }
        errors.removeAll { $0.source == source }
        persistErrors()
    }

    /// The user's Dismiss button: they have seen every error.
    func dismissAllErrors() {
        guard !errors.isEmpty else { return }
        errors.removeAll()
        persistErrors()
    }

    /// "Leave them behind": the notes stay in the old folder, so every
    /// path-keyed record about them would now point at nothing in the new
    /// folder (the ledgers store destination-relative paths). Forget them
    /// cleanly. Relay/spool names, handoff fingerprints, and transcript
    /// dispatch records are not path-keyed and are kept, so nothing is
    /// re-filed, re-created, or re-dispatched.
    func forgetFiledNotes() {
        state.update {
            $0.triagedRecords = []
            $0.enrichedLinkRecords = []
            $0.meetingRecords = []
        }
    }

    /// The Activity window's Undo: deletes a reminder or calendar event the
    /// handoff made and records that it was removed. Returns an error message
    /// for the window when the delete fails.
    @discardableResult
    func undoHandoff(_ event: ActivityEvent) -> String? {
        guard let undo = event.undo, !activity.undoneIDs.contains(event.id) else { return nil }
        let kind: HandoffKind = undo.kind == .reminder ? .reminder : .event
        do {
            try eventKit.deleteItem(kind: kind, identifier: undo.identifier)
        } catch {
            return "Couldn't remove it: \(error.localizedDescription)"
        }
        let what = undo.kind == .reminder ? "reminder" : "calendar event"
        let title = event.summary.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? event.summary
        activity.record(.info, source: .app, "Removed the \(what): \(title)", undoOf: event.id)
        return nil
    }

    private func persistErrors() {
        let snapshot = errors
        state.update {
            $0.errorRecords = snapshot
            $0.lastError = snapshot.max { $0.at < $1.at }?.message
        }
    }

    /// The single entry point for changing the output folder. Moves the existing notes tree
    /// to the new location (Dropbox-style), then switches the active folder and updates the
    /// downstream-consumer sidecar. Silent on success; on failure the source is left intact
    /// and the active folder is **not** changed.
    /// The user's answer before notes move (see `DestinationPrompts.consent`).
    enum RelocationChoice: Equatable, Sendable {
        case move
        /// Switch folders; the notes stay in the old folder and the app
        /// forgets them (their ledger records are pruned).
        case leaveBehind
        case cancel
    }

    typealias RelocationConsent = @MainActor (_ plan: OutputFolderMigrator.Plan, _ from: URL, _ to: URL) async -> RelocationChoice

    /// - Parameter consent: asked before anything moves, with a dry-run plan,
    ///   whenever the old folder holds files. nil (tests, programmatic calls)
    ///   means move, the pre-consent behavior.
    func setOutputFolder(_ newRaw: URL, consent: RelocationConsent? = nil) async {
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
            recordError("Couldn't move notes: \(message)", source: .folder)
            return
        }
        // Relocating AWAY FROM an absent volume: nothing can be moved off an
        // unplugged drive. Allowed (the user may need a working destination now),
        // but the stranded notes deserve an honest notice below.
        let oldVolumeAbsent = old.map { destinationGuard.check($0) == .volumeAbsent } ?? false

        // Consent before anything moves. Placed before the gate and before any
        // status changes, so Cancel is a clean, silent no-op.
        var choice = RelocationChoice.move
        var plan = OutputFolderMigrator.Plan()
        if let consent, let old, !oldVolumeAbsent {
            plan = await Task.detached(priority: .userInitiated) {
                OutputFolderMigrator().plan(from: old, to: new)
            }.value
            if !plan.isEmpty {
                choice = await consent(plan, old, new)
            }
        }
        guard choice != .cancel else { return }

        isRelocating = true
        relocationStatus = .inProgress

        await captureGate.withLock {
            do {
                // Run the file moves off the main actor so a large or cross-volume copy
                // doesn't freeze the Settings UI; the gate stays held throughout, so
                // capture writes remain blocked until the move completes.
                let report = try await Task.detached(priority: .userInitiated) { () -> OutputFolderMigrator.MigrationReport? in
                    let migrator = OutputFolderMigrator()
                    if let old, choice == .move {
                        return try migrator.migrate(from: old, to: new)
                    } else {
                        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
                        return nil
                    }
                }.value
                settings.update { $0.outputFolder = new }
                // Collision-renamed notes: keep the triage and enriched-link
                // ledgers' recorded destinations pointing at the real files.
                if let report, !report.renamedNotes.isEmpty {
                    TriageLedger(stateStore: state).remap(report.renamedNotes)
                    EnrichedLinkLedger(stateStore: state).remap(report.renamedNotes)
                    TranscriptDispatchLedger(stateStore: state).remap(report.renamedNotes)
                    MeetingLedger(stateStore: state).remap(report.renamedNotes)
                }
                if choice == .leaveBehind {
                    forgetFiledNotes()
                    activity.record(.info, source: .app, "Notes folder changed to \(new.lastPathComponent). \(plan.noteCount) earlier \(plan.noteCount == 1 ? "note stays" : "notes stay") in \(old?.lastPathComponent ?? "the old folder").", path: new)
                } else if plan.noteCount > 0 {
                    activity.record(.info, source: .app, "Moved \(plan.noteCount) \(plan.noteCount == 1 ? "note" : "notes") to \(new.lastPathComponent).", path: new)
                }
                OutputFolderSidecar.write(new)
                // Opt-in; no-op unless the new folder ended up empty + CLAUDE.md-less.
                if settings.settings.seedScaffold {
                    OutputFolderScaffold.seedIfEligible(folder: new)
                }
                relocationStatus = .idle
                if oldVolumeAbsent {
                    recordError("Your previous notes are still on the disconnected drive. Reconnect it and switch the folder back to move them.", source: .folder)
                } else {
                    clearError(source: .folder)
                }
            } catch {
                let message = error.localizedDescription
                relocationStatus = .failed(message)
                recordError("Couldn't move notes: \(message)", source: .folder)
            }
        }

        isRelocating = false
    }
}
