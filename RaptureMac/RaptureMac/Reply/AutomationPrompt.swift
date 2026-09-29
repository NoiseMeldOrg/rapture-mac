import AppKit
import Foundation

@MainActor
enum AutomationPrompt {
    private static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    enum PrePromptResult {
        case proceed
        /// The user doesn't want replies: reply mode is switched to Never.
        case noReplies
    }

    @discardableResult
    static func showPrePrompt(settings: SettingsStore? = nil) -> PrePromptResult {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rapture is about to reply in your Messages thread"
        alert.informativeText = """
            So you'll get a "✅ Saved" confirmation on your iPhone after each capture, Rapture sends a short reply in the Messages thread the note arrived on.

            macOS will ask whether to allow that. Click OK on the next prompt. Your note is already saved either way.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Don't Send Replies")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            settings?.update { $0.replyMode = .off }
            return .noReplies
        }
        return .proceed
    }

    static func showDenied() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rapture needs Automation access for Messages"
        alert.informativeText = """
            Rapture wasn't able to send a confirmation reply because macOS blocked Automation access for Messages.app.

            Open System Settings → Privacy & Security → Automation, find Rapture, and turn Messages on.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(automationSettingsURL)
        }
    }
}
