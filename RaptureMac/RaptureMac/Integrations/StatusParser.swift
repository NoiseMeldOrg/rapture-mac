import Foundation

struct StatusReport: Equatable, Sendable {
    struct Hook: Equatable, Sendable {
        var scriptInstalled: Bool = false
        var registered: Bool = false
    }

    struct NotesFolder: Equatable, Sendable {
        var path: String?
        var source: String?
        var pending: Int?
        var claudeMdPresent: Bool = false
    }

    var hook: Hook = Hook()
    var notesFolder: NotesFolder = NotesFolder()

    static let empty = StatusReport()
}

enum StatusParser {
    /// Parses `Scripts/status.sh` output into a typed report. Pure function.
    /// Unknown lines are ignored; missing sections leave the relevant fields at defaults.
    nonisolated static func parse(_ stdout: String) -> StatusReport {
        var report = StatusReport()
        var section: Section = .none

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripANSI(String(rawLine))

            if let newSection = detectSection(line: line) {
                section = newSection
                continue
            }

            switch section {
            case .none:           break
            case .hook:           parseHook(line: line, into: &report.hook)
            case .notesFolder:    parseNotesFolder(line: line, into: &report.notesFolder)
            case .commands:       break
            }
        }

        return report
    }

    // MARK: - Sections

    private enum Section { case none, hook, notesFolder, commands }

    private nonisolated static func detectSection(line: String) -> Section? {
        if line.hasPrefix("SessionStart hook")      { return .hook }
        if line.hasPrefix("Notes folder:")          { return .notesFolder }
        if line.hasPrefix("Commands:")              { return .commands }
        return nil
    }

    // MARK: - Hook

    private nonisolated static func parseHook(line: String, into hook: inout StatusReport.Hook) {
        let body = stripMarker(line)
        if body.hasPrefix("Check script: ") {
            hook.scriptInstalled = true
        } else if body == "Check script not installed" {
            hook.scriptInstalled = false
        } else if body.hasPrefix("Registered in ") {
            hook.registered = true
        } else if body.hasPrefix("Not registered") {
            hook.registered = false
        }
    }

    // MARK: - Notes folder

    private nonisolated static func parseNotesFolder(line: String, into notes: inout StatusReport.NotesFolder) {
        let body = stripMarker(line)
        // Path: and Source: lines have variable whitespace after the colon.
        if let value = matchPrefix("Path:", in: body) {
            notes.path = value
        } else if let value = matchPrefix("Source:", in: body) {
            notes.source = value
        } else if let value = matchPrefix("Pending:", in: body) {
            // value is e.g. "3 .txt file(s) in root"
            let parts = value.split(separator: " ", maxSplits: 1)
            if let first = parts.first, let n = Int(first) {
                notes.pending = n
            }
        } else if body.hasPrefix("CLAUDE.md routing rules present") {
            notes.claudeMdPresent = true
        } else if body.hasPrefix("CLAUDE.md routing rules missing") {
            notes.claudeMdPresent = false
        } else if body.hasPrefix("Folder does not exist") {
            notes.claudeMdPresent = false
        }
    }

    /// Matches `<prefix><whitespace><value>` and returns the trimmed value, else nil.
    private nonisolated static func matchPrefix(_ prefix: String, in body: String) -> String? {
        guard body.hasPrefix(prefix) else { return nil }
        let rest = body.dropFirst(prefix.count)
        let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    // MARK: - Line preprocessing

    /// Strips leading whitespace, `✓ `, `✗ ` so individual matchers see the body only.
    /// status.sh prefixes every fact line with two spaces and a glyph; some auxiliary
    /// lines (Path:, Source:, Pending:) have just the two spaces.
    nonisolated static func stripMarker(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("✓ ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("✗ ") { return String(trimmed.dropFirst(2)) }
        return String(trimmed)
    }

    /// Strips ANSI SGR escapes (e.g. `\u{1B}[32m`, `\u{1B}[0m`) that status.sh
    /// emits unconditionally via its mark() helper.
    nonisolated static func stripANSI(_ line: String) -> String {
        let regex = #/\u{1B}\[[0-9;]*m/#
        return line.replacing(regex, with: "")
    }
}
