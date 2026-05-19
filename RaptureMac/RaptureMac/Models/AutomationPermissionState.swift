import Foundation

enum AutomationPermissionState: Equatable, Sendable {
    case unknown
    case prePromptPending
    case required
    case ok
}
