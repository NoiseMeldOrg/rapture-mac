import Foundation

/// Gathers Rapture's own folders out of a vault root into one container
/// (onboarding M3), for users whose notes folder is the vault itself and whose
/// `Notes/`, `Links/`, `Tasks/`… sit loose among the vault's own folders.
///
/// `OutputFolderMigrator.migrate` can't do this: it refuses nested paths
/// (`<vault>` → `<vault>/Rapture Inbox`) and moves every top-level item,
/// dotfiles included, which here would carry off `.obsidian/` and the user's
/// notes. This moves only items proven to be Rapture's, and never touches
/// anything else. All-or-nothing: if any Rapture-named folder also holds the
/// user's own notes, nothing is offered.
enum VaultRootRescue {

    /// Rapture's class folders at a notes-folder root.
    nonisolated static let classFolders = ["Notes", "Links", "Tasks", "Ideas", "Journal", "Meetings"]

    struct Offer: Equatable, Sendable {
        let root: URL
        /// Top-level names to move: class folders and raw-mode captures.
        let items: [String]
    }

    /// An offer when `root` is a vault root (has `.obsidian`) holding
    /// Rapture's folders loose; nil otherwise.
    nonisolated static func offer(for root: URL, fileManager: FileManager = .default) -> Offer? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path),
              entries.contains(".obsidian") else { return nil }
        var items: [String] = []
        for name in classFolders where entries.contains(name) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            switch ownership(of: folder, isLinks: name == "Links", fileManager: fileManager) {
            case .rapture: items.append(name)
            case .empty: continue
            case .mixed: return nil // the user's own notes are in there: touch nothing
            }
        }
        // Raw-mode captures at the root: ISO-named .txt files and their
        // attachment folders.
        for name in entries.sorted() where RelayWatcher.parseRelayTimestamp(name) != nil && !name.hasPrefix(".") {
            items.append(name)
        }
        return items.isEmpty ? nil : Offer(root: root, items: items)
    }

    enum Ownership: Equatable { case rapture, empty, mixed }

    /// A class folder is Rapture's when every note file in it carries the
    /// capture contract header (`captured:` in its YAML frontmatter). Files
    /// inside a note's attachment folder belong to that note; everything in
    /// `Links/Media/` is Rapture's enrichment output.
    nonisolated static func ownership(of folder: URL, isLinks: Bool, fileManager: FileManager = .default) -> Ownership {
        guard let children = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return .empty }
        let visible = children.filter { !$0.hasPrefix(".") }
        var sawNote = false
        let noteBases = Set(visible.filter { OutputFolderMigrator.isNoteExtension(($0 as NSString).pathExtension) }
            .map { ($0 as NSString).deletingPathExtension })
        for name in visible {
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                if isLinks && name == "Media" { continue }
                if noteBases.contains(name) { continue } // a note's attachments
                return .mixed // a subfolder Rapture never makes
            }
            guard OutputFolderMigrator.isNoteExtension(url.pathExtension), hasCaptureHeader(url) else {
                return .mixed
            }
            sawNote = true
        }
        return sawNote ? .rapture : .empty
    }

    nonisolated static func hasCaptureHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024) else { return false }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return false }
        for line in lines.dropFirst() {
            if line == "---" { return false }
            if line.hasPrefix("captured: ") { return true }
        }
        return false
    }

    /// Moves `offer.items` into `root/<containerName>`, merging into what is
    /// already there without overwriting. Returns destination-relative renames
    /// (relative to the container, the new notes folder) for the ledger remaps.
    nonisolated static func gather(_ offer: Offer, into containerName: String, fileManager: FileManager = .default) throws -> [String: String] {
        let container = offer.root.appendingPathComponent(containerName, isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        var renames: [String: String] = [:]
        for name in offer.items {
            let source = offer.root.appendingPathComponent(name)
            let dest = container.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: source.path, isDirectory: &isDir)
            if !fileManager.fileExists(atPath: dest.path) {
                try fileManager.moveItem(at: source, to: dest)
            } else if isDir.boolValue {
                // Same-named folder already in the container: merge, never clobber.
                let report = try OutputFolderMigrator(fileManager: fileManager).migrate(from: source, to: dest)
                for (from, to) in report.renamedNotes {
                    renames["\(name)/\(from)"] = "\(name)/\(to)"
                }
            } else {
                let base = (name as NSString).deletingPathExtension
                let (free, _) = FileWriter.uniqueDestination(in: container, baseName: base, fileExtension: (name as NSString).pathExtension)
                try fileManager.moveItem(at: source, to: free)
                renames[name] = free.lastPathComponent
            }
        }
        return renames
    }
}
