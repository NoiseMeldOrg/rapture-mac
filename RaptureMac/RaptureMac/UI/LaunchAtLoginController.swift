import Foundation
import OSLog
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`. Treats the system as the source of truth:
/// the UI toggle reads `isEnabled` synchronously and writes via `setEnabled(_:)`.
@MainActor
enum LaunchAtLoginController {
    private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Registers or unregisters the main-app login item. Throws on failure so the UI can show
    /// a localized error inline. macOS may surface a one-time approval prompt the first time.
    static func setEnabled(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            try service.register()
            log.info("Registered as login item.")
        } else {
            try service.unregister()
            log.info("Unregistered as login item.")
        }
    }
}
