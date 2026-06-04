import Foundation

struct PrerequisiteReport: Equatable, Sendable {
    let missingCLIs: [String]
    let missingBrew: [String]
    let tccDeepLinks: [TCCEntry]

    var allCLIsPresent: Bool { missingCLIs.isEmpty && missingBrew.isEmpty }

    /// Combined missing items with the install command to surface in the UI sheet.
    var missingItems: [MissingItem] {
        var items: [MissingItem] = []
        for cli in missingCLIs where !cli.isEmpty {
            items.append(MissingItem(name: cli, installCommand: Prerequisites.installCommands[cli] ?? "brew install \(cli)"))
        }
        for pkg in missingBrew where !pkg.isEmpty {
            items.append(MissingItem(name: pkg, installCommand: Prerequisites.installCommands[pkg] ?? "brew install \(pkg)"))
        }
        return items
    }
}

struct MissingItem: Identifiable, Equatable, Sendable {
    let name: String
    let installCommand: String
    var id: String { name }
}

struct TCCEntry: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    var id: String { name }
}

enum Prerequisites {
    /// Canonical install commands for prerequisites the panel knows about. Keys are
    /// the CLI/package names that appear in a manifest's `requires.cli` or
    /// `requires.brew` lists. Unknown items fall back to `brew install <name>` in
    /// `MissingItem.installCommand`.
    static let installCommands: [String: String] = [
        "jq":       "brew install jq",
        "claude":   "brew install --cask claude-code",
        "rg":       "brew install ripgrep",
        "fd":       "brew install fd"
    ]

    /// `x-apple.systempreferences:` URLs for the Privacy & Security panes a consumer
    /// might want pre-granted. Unknown TCC names render a button that opens the
    /// Privacy & Security root pane.
    private static let tccURLs: [String: URL] = [
        "Calendar":       URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendar")!,
        "Contacts":       URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!,
        "Accessibility":  URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
        "FullDiskAccess": URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!,
        "Automation":     URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    ]

    private static let privacyRootURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!

    nonisolated static func tccURL(for name: String) -> URL {
        tccURLs[name] ?? privacyRootURL
    }

    /// Detects which prerequisites are present on the host by shelling out to
    /// `/usr/bin/which`. Pure-ish (filesystem access only). Synchronous; intended
    /// to be called from a `Task.detached` block at panel-render time.
    nonisolated static func detect(_ requires: Requires) -> PrerequisiteReport {
        let tccEntries = requires.tcc.map { TCCEntry(name: $0, url: tccURL(for: $0)) }
        return PrerequisiteReport(
            missingCLIs: requires.cli.filter { !whichExits($0) },
            missingBrew: requires.brew.filter { !whichExits($0) },
            tccDeepLinks: tccEntries
        )
    }

    /// Like `detect`, but also allows the caller to inject a custom lookup so tests
    /// can stub the filesystem check.
    nonisolated static func detect(_ requires: Requires, exists: (String) -> Bool) -> PrerequisiteReport {
        let tccEntries = requires.tcc.map { TCCEntry(name: $0, url: tccURL(for: $0)) }
        return PrerequisiteReport(
            missingCLIs: requires.cli.filter { !exists($0) },
            missingBrew: requires.brew.filter { !exists($0) },
            tccDeepLinks: tccEntries
        )
    }

    /// Returns true if `/usr/bin/which <name>` exits zero, i.e. the binary is on PATH.
    /// PATH is whatever the calling process has — which for the live app is the
    /// login shell PATH captured at launch, not just the .app's minimal default.
    nonisolated static func whichExits(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
