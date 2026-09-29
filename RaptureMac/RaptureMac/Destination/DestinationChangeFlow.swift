import Foundation

/// The "where should notes go" decision, from a chosen folder to the final
/// notes folder. Shape copied from `HandoffEnableFlow`: a `@MainActor enum`
/// with injected prompt closures, so tests drive every branch without a
/// dialog. `AppState.setOutputFolder` then asks consent and moves the notes.
@MainActor
enum DestinationChangeFlow {

    enum ContainmentAnswer: Equatable {
        /// Put Rapture's output in this subfolder of the chosen folder.
        case contain(name: String)
        /// Write straight into the chosen folder.
        case useFolder
        case cancel
    }

    /// Asked when the chosen folder holds the user's own things. `problem`
    /// explains why the previous answer can't be used (non-nil on a re-ask).
    typealias ContainmentPrompt = @MainActor (_ folder: URL, _ suggestedName: String, _ problem: String?) -> ContainmentAnswer

    /// The folder notes should actually go to, or nil when the user cancelled.
    static func resolveTarget(
        chosen: URL,
        prompt: ContainmentPrompt,
        listDirectory: (URL) -> [String]? = Self.liveList
    ) -> URL? {
        let folder = chosen.standardizedFileURL
        guard let entries = listDirectory(folder),
              Containment.decide(entries: entries) == .offerContainer else {
            return folder // missing (will be created), empty, or already Rapture's
        }

        var suggested = Containment.defaultContainerName
        var problem: String?
        // Bounded: a user typing name after name that all collide still gets
        // out through Cancel; the loop can't spin without a prompt answer.
        while true {
            switch prompt(folder, suggested, problem) {
            case .cancel:
                return nil
            case .useFolder:
                return folder
            case .contain(let rawName):
                guard let name = Containment.sanitizedContainerName(rawName) else {
                    problem = "That name can't be used for a folder. Try another."
                    continue
                }
                let container = folder.appendingPathComponent(name, isDirectory: true)
                switch Containment.checkContainer(entries: listDirectory(container)) {
                case .adopt:
                    return container
                case .conflict:
                    problem = "\"\(name)\" already holds other files. Pick a different name so Rapture's notes don't mix with them."
                    suggested = nextFreeName(after: name, in: folder, listDirectory: listDirectory)
                }
            }
        }
    }

    /// "Rapture Inbox 2", "Rapture Inbox 3"… the first one that is free or ours.
    static func nextFreeName(after name: String, in folder: URL, listDirectory: (URL) -> [String]?) -> String {
        var n = 2
        while n < 100 {
            let candidate = "\(name) \(n)"
            if Containment.checkContainer(entries: listDirectory(folder.appendingPathComponent(candidate))) == .adopt {
                return candidate
            }
            n += 1
        }
        return name
    }

    /// nil when the path doesn't exist (or isn't a directory).
    nonisolated static func liveList(_ url: URL) -> [String]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// Picker → containment → consent → move. The one path every "change
    /// the notes folder" entry point uses (menu, Choose Another Folder…, drop).
    static func change(
        to chosen: URL,
        appState: AppState,
        prompt: ContainmentPrompt = DestinationPrompts.containment,
        consent: @escaping AppState.RelocationConsent = DestinationPrompts.consent
    ) async {
        guard let target = resolveTarget(chosen: chosen, prompt: prompt) else { return }
        await appState.setOutputFolder(target, consent: consent)
    }
}
