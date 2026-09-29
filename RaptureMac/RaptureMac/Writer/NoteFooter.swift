import Foundation

/// Rebuilds a filed note's trailing `Attachments:` footer from what is really
/// in its attachment folder. Used when files join a note after it was written:
/// a meeting's late audio, or an iMessage photo that downloaded after filing.
/// Both footer formats: Markdown links (`CaptureContract.compose`) and the raw
/// `- folder/file` list (`FileWriter.composeBody`). Pure except `attachmentFiles`.
enum NoteFooter {

    /// Strips a well-formed trailing footer and appends one listing `files`.
    /// With no files the footer is simply dropped. A lookalike block in prose
    /// is body text and stays.
    nonisolated static func replacing(in text: String, isMarkdown: Bool, folder: String, files: [String]) -> String {
        if isMarkdown {
            var head = text
            if let range = text.range(of: "\nAttachments:\n", options: .backwards),
               isMarkdownFooter(text[range.upperBound...]) {
                // The match starts at the second newline of the blank line
                // before the footer, so the head keeps its own trailing newline.
                head = String(text[..<range.lowerBound])
            }
            guard !files.isEmpty else { return head }
            let lines = files.map { "- [\($0)](<\(folder)/\($0)>)" }
            return head + (head.isEmpty ? "" : "\n") + "Attachments:\n" + lines.joined(separator: "\n") + "\n"
        }
        let body = CaptureContract.parseFooter(text)?.bodyWithoutFooter ?? text
        return FileWriter.composeBody(text: body, copiedAttachments: files.map { (folder: folder, filename: $0) })
    }

    nonisolated static func isMarkdownFooter(_ footer: Substring) -> Bool {
        let lines = footer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("- [") && $0.contains("](<") && $0.hasSuffix(">)") }
    }

    /// Visible regular files in an attachment folder, sorted.
    nonisolated static func attachmentFiles(in dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") && !MeetingFiler.isDirectory(dir.appendingPathComponent($0)) }
            .sorted()
    }
}
