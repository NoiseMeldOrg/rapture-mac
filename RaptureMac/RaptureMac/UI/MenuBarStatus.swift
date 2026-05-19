import Foundation

/// Computes the menu-bar status presentation from the four signal sources.
/// Priority (highest first): FDA needed > Automation needed > Paused > Error > Capturing.
/// Pure so the priority order can be unit-tested without a SwiftUI host.
enum MenuBarStatus {
    enum Kind: Equatable {
        case capturing
        case paused
        case fullDiskAccessNeeded
        case automationNeeded
        case error
    }

    struct Line: Equatable {
        var kind: Kind
        var primary: String
        var iconName: String
    }

    static func line(
        permission: AppState.PermissionState,
        automation: AutomationPermissionState,
        paused: Bool,
        lastError: String?
    ) -> Line {
        if permission == .fullDiskAccessRequired {
            return Line(kind: .fullDiskAccessNeeded, primary: "⚠ Full Disk Access needed", iconName: "exclamationmark.triangle.fill")
        }
        if automation == .required {
            return Line(kind: .automationNeeded, primary: "⚠ Automation access needed", iconName: "exclamationmark.triangle.fill")
        }
        if paused {
            return Line(kind: .paused, primary: "⏸ Paused", iconName: "pause.fill")
        }
        if let err = lastError, !err.isEmpty {
            return Line(kind: .error, primary: "⚠ \(err)", iconName: "exclamationmark.triangle.fill")
        }
        return Line(kind: .capturing, primary: "✓ Capturing", iconName: "text.bubble")
    }
}
