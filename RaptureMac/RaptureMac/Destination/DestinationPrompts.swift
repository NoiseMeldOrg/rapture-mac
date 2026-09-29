import AppKit

/// The real dialogs behind `DestinationChangeFlow` and the relocation consent
/// (`NSAlert`, the `AutomationPrompt` pattern). Never used under tests: every
/// caller that tests exercise takes the prompts as injected closures.
@MainActor
enum DestinationPrompts {

    static func containment(folder: URL, suggestedName: String, problem: String?) -> DestinationChangeFlow.ContainmentAnswer {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep Rapture's notes in one folder?"
        var info = "“\(folder.lastPathComponent)” already has your own files. Rapture can put its folders (Notes, Links, Tasks and the rest) inside one subfolder, so they don't mix with yours."
        if let problem { info = problem + "\n\n" + info }
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggestedName
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Subfolder")
        alert.addButton(withTitle: "Use “\(folder.lastPathComponent)” Itself")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .contain(name: field.stringValue)
        case .alertSecondButtonReturn: return .useFolder
        default: return .cancel
        }
    }

    static func consent(plan: OutputFolderMigrator.Plan, from old: URL, to new: URL) async -> AppState.RelocationChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let notes = plan.noteCount == 1 ? "1 note" : "\(plan.noteCount) notes"
        alert.messageText = "Move your notes to the new folder?"
        var info = "\(notes) (with their attachments) will move\nfrom: \(old.path(percentEncoded: false))\nto: \(new.path(percentEncoded: false))"
        if plan.collisionCount > 0 {
            info += "\n\n\(plan.collisionCount) \(plan.collisionCount == 1 ? "file has" : "files have") the same name as one already there. Nothing is overwritten: those get a number added to the name."
        }
        info += "\n\n“Leave Them Behind” switches folders but keeps the old notes where they are. Rapture then forgets about them."
        alert.informativeText = info
        alert.addButton(withTitle: "Move Them")
        alert.addButton(withTitle: "Leave Them Behind")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .move
        case .alertSecondButtonReturn: return .leaveBehind
        default: return .cancel
        }
    }
}
