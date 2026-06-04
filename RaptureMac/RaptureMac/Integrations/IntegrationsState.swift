import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class IntegrationsState {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "IntegrationsState")

    /// Transient per-install action state; drives button disable/spinner UX.
    enum ActionState: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    /// What kind of action a button press dispatches.
    enum ActionKind: String, Sendable {
        case install, uninstall
    }

    /// All discovered consumer cards (sorted by folder name; stable across launches).
    private(set) var cards: [ConsumerCard]

    /// Latest parsed status.sh output. `nil` until first poll completes.
    private(set) var status: StatusReport?

    /// Latest prerequisite report per install id.
    private(set) var prereqs: [String: PrerequisiteReport] = [:]

    /// Transient per-install action state, keyed by install id.
    private(set) var pendingActions: [String: ActionState] = [:]

    @ObservationIgnored private let runner: IntegrationRunning
    @ObservationIgnored private let scriptsRoot: URL
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        runner: IntegrationRunning,
        examplesRoot: URL,
        scriptsRoot: URL
    ) {
        self.runner = runner
        self.scriptsRoot = scriptsRoot

        do {
            self.cards = try IntegrationDiscovery.discover(
                examplesRoot: examplesRoot,
                scriptsRoot: scriptsRoot
            )
        } catch {
            Self.log.error("Discovery failed: \(error.localizedDescription, privacy: .public)")
            self.cards = []
        }

        self.prereqs = Self.computeAllPrereqs(cards: cards)
    }

    // MARK: - Status polling

    /// Starts a polling loop that refreshes `status` from status.sh every `interval`
    /// seconds. Safe to call repeatedly — replaces any existing polling task.
    func startPolling(interval: TimeInterval = 5.0) {
        stopPolling()
        let statusURL = scriptsRoot.appendingPathComponent("status.sh")
        let runner = self.runner
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await runner.run(statusURL, env: [:])
                    let parsed = StatusParser.parse(result.stdout)
                    self?.status = parsed
                } catch {
                    Self.log.error("status.sh failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One-off refresh — useful right after an install/uninstall to update the pill
    /// without waiting for the next poll tick.
    func refreshStatusNow() async {
        let statusURL = scriptsRoot.appendingPathComponent("status.sh")
        do {
            let result = try await runner.run(statusURL, env: [:])
            status = StatusParser.parse(result.stdout)
        } catch {
            Self.log.error("status.sh refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    /// Dispatches an action on an install profile. Updates `pendingActions[install.id]`
    /// to `.running` immediately, runs the script, sets `.succeeded` or `.failed(...)`
    /// based on exit code, then refreshes status.
    func run(_ action: ActionKind, for install: InstallProfile, env: [String: String] = [:]) async {
        guard let scriptURL = url(for: action, in: install) else {
            pendingActions[install.id] = .failed("\(action.rawValue) script not declared in manifest")
            return
        }

        pendingActions[install.id] = .running
        do {
            let result = try await runner.run(scriptURL, env: env)
            if result.succeeded {
                pendingActions[install.id] = .succeeded
            } else {
                let firstStderrLine = result.stderr
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? "exit \(result.exitCode)"
                pendingActions[install.id] = .failed(firstStderrLine)
            }
        } catch {
            pendingActions[install.id] = .failed(error.localizedDescription)
        }
        await refreshStatusNow()
        refreshPrereqs(for: install.id)
    }

    /// Resets the transient action state for an install. Use after the user dismisses
    /// a success/failure result toast or after a short delay.
    func clearPendingAction(for installID: String) {
        pendingActions.removeValue(forKey: installID)
    }

    private nonisolated static func computeAllPrereqs(cards: [ConsumerCard]) -> [String: PrerequisiteReport] {
        var dict: [String: PrerequisiteReport] = [:]
        for card in cards {
            for install in card.installs {
                dict[install.id] = Prerequisites.detect(install.requires)
            }
        }
        return dict
    }

    private func refreshPrereqs(for installID: String) {
        guard let install = installProfile(id: installID) else { return }
        prereqs[installID] = Prerequisites.detect(install.requires)
    }

    private func installProfile(id: String) -> InstallProfile? {
        for card in cards {
            if let profile = card.installs.first(where: { $0.id == id }) {
                return profile
            }
        }
        return nil
    }

    private nonisolated func url(for action: ActionKind, in install: InstallProfile) -> URL? {
        switch action {
        case .install:   return install.install
        case .uninstall: return install.uninstall
        }
    }
}
