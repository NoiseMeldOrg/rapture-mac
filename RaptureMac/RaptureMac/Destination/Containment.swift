import Foundation

/// Decides whether a chosen folder can take Rapture's output directly, or
/// whether the output should be kept together in one subfolder so it never
/// scatters `Notes/`, `Links/`, `Tasks/`… among the user's own folders.
/// Pure over directory listings; tested by table.
enum Containment {
    nonisolated static let defaultContainerName = "Rapture Inbox"

    enum Decision: Equatable {
        /// Empty, or already a Rapture notes tree: write into it directly.
        case useDirectly
        /// Holds the user's own things (or is a vault): offer a subfolder.
        case offerContainer
    }

    enum ContainerCheck: Equatable {
        /// Free, empty, or already Rapture's: use it.
        case adopt
        /// Holds unrelated content: suggest a different name instead of mixing in.
        case conflict
    }

    /// Names Rapture itself creates at the root of its notes folder.
    nonisolated static let raptureRootNames: Set<String> = [
        "Notes", "Links", "Tasks", "Ideas", "Journal", "Meetings", "CLAUDE.md"
    ]

    /// `entries` is the folder's listing (names, including hidden ones).
    nonisolated static func decide(entries: [String]) -> Decision {
        // A vault root is a vault even when it looks empty to Finder.
        if entries.contains(".obsidian") { return .offerContainer }
        let visible = entries.filter { !$0.hasPrefix(".") }
        if visible.isEmpty || looksLikeRaptureTree(visible) { return .useDirectly }
        return .offerContainer
    }

    /// Every visible item is something Rapture writes at its root: a class
    /// folder, the optional `CLAUDE.md`, or raw-mode capture files named by
    /// their ISO timestamp (and their attachment folders).
    nonisolated static func looksLikeRaptureTree(_ visible: [String]) -> Bool {
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { name in
            raptureRootNames.contains(name) || RelayWatcher.parseRelayTimestamp(name) != nil
        }
    }

    /// `entries` is nil when the container folder doesn't exist yet.
    nonisolated static func checkContainer(entries: [String]?) -> ContainerCheck {
        guard let entries else { return .adopt }
        if entries.contains(".obsidian") { return .conflict }
        let visible = entries.filter { !$0.hasPrefix(".") }
        if visible.isEmpty || looksLikeRaptureTree(visible) { return .adopt }
        return .conflict
    }

    /// A folder name safe to create: no path separators, not empty, not a
    /// dot-name. nil when nothing usable remains.
    nonisolated static func sanitizedContainerName(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { return nil }
        return cleaned
    }
}
