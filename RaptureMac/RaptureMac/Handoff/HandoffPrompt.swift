import AppKit
import Foundation

/// Plain-language pre-prompt before the Reminders/Calendars TCC dialogs, and
/// the after-deny nudge with a System Settings deep link. Same shape as
/// `AutomationPrompt`; kind-parameterized because the two grants are separate
/// on macOS 14+. Cancel just aborts the toggle (unlike Automation's Quit —
/// handoff is optional, replies are core).
@MainActor
enum HandoffPrompt {
    enum PrePromptResult {
        case proceed
        case cancel
    }

    static func settingsURL(for kind: HandoffKind) -> URL {
        switch kind {
        case .reminder:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
        case .event:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        }
    }

    @discardableResult
    static func showPrePrompt(kind: HandoffKind) -> PrePromptResult {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch kind {
        case .reminder:
            alert.messageText = "Rapture is about to ask for Reminders access"
            alert.informativeText = """
                With Reminders handoff on, a capture that clearly says "remind me to…" also becomes an Apple Reminder (the note still files either way).

                macOS will ask whether to allow access to your reminders. Click Allow Full Access on the next prompt.
                """
        case .event:
            alert.messageText = "Rapture is about to ask for Calendar access"
            alert.informativeText = """
                With Calendar handoff on, a capture that states an appointment with a date and time also becomes a 1-hour calendar event (the note still files either way).

                macOS will ask whether to allow access to your calendar. Click Allow Full Access on the next prompt.
                """
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .proceed : .cancel
    }

    static func showDenied(kind: HandoffKind) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rapture needs \(kind.displayName) access for handoff"
        let pane = kind == .reminder ? "Reminders" : "Calendars"
        alert.informativeText = """
            macOS blocked \(kind.displayName) access, so the handoff toggle stays off.

            Open System Settings → Privacy & Security → \(pane), find Rapture, and allow Full Access — then flip the toggle again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL(for: kind))
        }
    }
}
