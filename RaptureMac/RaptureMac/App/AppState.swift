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

    var permissionState: PermissionState = .unknown
    var automationPermissionState: AutomationPermissionState = .unknown
    var lastError: String?
    var lastErrorAt: Date?

    let settings: SettingsStore
    let state: StateStore

    init() {
        self.settings = SettingsStore()
        self.state = StateStore()
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
}
