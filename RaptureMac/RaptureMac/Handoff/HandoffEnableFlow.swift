import Foundation

/// The toggle-enable decision, extracted from the Settings view so it's
/// testable with a fake client and injected prompt closures. This is the ONLY
/// place the app ever requests EventKit access — never at launch, never from
/// the filing path.
@MainActor
enum HandoffEnableFlow {
    struct Result: Equatable {
        /// True when the toggle may persist ON.
        var enabled: Bool
        /// A caption-worthy error when the grant was declined or missing.
        var error: String?
    }

    static func enable(
        kind: HandoffKind,
        client: any EventKitClient,
        prePrompt: @MainActor () -> Bool,
        showDenied: @MainActor () -> Void
    ) async -> Result {
        let pane = kind == .reminder ? "Reminders" : "Calendars"
        switch client.authorizationStatus(for: kind) {
        case .authorized:
            return Result(enabled: true, error: nil)
        case .notDetermined:
            // Pre-prompt first (house pattern): the OS dialog must never appear
            // unexplained. Cancelling the pre-prompt aborts silently.
            guard prePrompt() else { return Result(enabled: false, error: nil) }
            if await client.requestAccess(for: kind) {
                return Result(enabled: true, error: nil)
            }
            showDenied()
            return Result(
                enabled: false,
                error: "\(kind.displayName) access was declined — allow it in System Settings › Privacy & Security › \(pane), then try again."
            )
        case .denied:
            showDenied()
            return Result(
                enabled: false,
                error: "\(kind.displayName) access is off — allow it in System Settings › Privacy & Security › \(pane), then try again."
            )
        }
    }
}
