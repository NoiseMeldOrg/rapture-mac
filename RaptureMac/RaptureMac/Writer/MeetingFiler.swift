import Foundation
import OSLog

/// Files meeting relay parts (see `MeetingMarker`) as ONE note per meeting.
///
/// The first part to arrive creates the note; a later summary rewrites it in
/// place: new body, and a rename when the title changed. The note's attachment
/// folder (the transcript's audio) moves with it, and the footer is rebuilt from
/// what is actually in that folder, so audio filed with the transcript survives
/// every summary. No AI, no handoffs, no enrichment: the body is the verbatim
/// meeting text minus the marker line.
///
/// `.full` mode: `Meetings/YYYY-MM-DD <title>.md`, contract frontmatter with
/// `type: meeting` and `meeting_id`. `.raw` mode keeps the raw contract: a
/// root `.txt` named by the relay basename, holding the relay text verbatim
/// (marker included, so the file stays recognizable as a meeting if the user
/// later switches triage on). Raw mode also keeps one file per meeting: a
/// summary rewrites the file and takes the summary's relay basename.
@MainActor
final class MeetingFiler {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "MeetingFiler")

    nonisolated static let fallbackTitle = "Meeting"

    private let destinationGuard: DestinationGuard

    init(destinationGuard: DestinationGuard = DestinationGuard()) {
        self.destinationGuard = destinationGuard
    }

    // MARK: - Write / replace

    /// Creates the meeting's note (`existingNote == nil`) or rewrites it. The
    /// returned URL is where the note lives afterwards.
    func write(
        _ meeting: MeetingMarker.Parsed,
        rawText: String,
        relayBaseName: String,
        capturedAt: Date,
        existingNote: URL?,
        audioURL: URL?,
        mode: TriageMode,
        to folder: URL,
        timeZone: TimeZone = .current
    ) async -> WriteResult {
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        let fm = FileManager.default
        do {
            let full = mode == .full
            let targetDir = full
                ? folder.appendingPathComponent(CaptureType.meeting.subfolder, isDirectory: true)
                : folder
            let ext = full ? "md" : "txt"
            let base: String
            if full {
                let title = TitleDeriver.relayTitle(fromBaseName: relayBaseName)
                    ?? MeetingMarker.headingTitle(of: meeting.body)
                    ?? Self.fallbackTitle
                base = CaptureContract.filenameBase(title: title, capturedAt: capturedAt, timeZone: timeZone)
            } else {
                base = relayBaseName
            }
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

            // Where the note goes: stay put when directory, format, and name all
            // still fit (including an earlier `-N` collision suffix); otherwise a
            // fresh collision-free name.
            let noteURL: URL
            let attachmentName: String
            if let existing = existingNote,
               existing.deletingLastPathComponent().standardizedFileURL == targetDir.standardizedFileURL,
               existing.pathExtension == ext,
               Self.baseMatches(existing.deletingPathExtension().lastPathComponent, base: base) {
                noteURL = existing
                attachmentName = existing.deletingPathExtension().lastPathComponent
            } else {
                (noteURL, attachmentName) = FileWriter.uniqueDestination(in: targetDir, baseName: base, fileExtension: ext)
            }
            let attachmentDir = targetDir.appendingPathComponent(attachmentName, isDirectory: true)

            // The attachment folder follows its note.
            var movedFrom: URL?
            if let existing = existingNote {
                let oldDir = existing.deletingPathExtension()
                if Self.isDirectory(oldDir), oldDir.standardizedFileURL != attachmentDir.standardizedFileURL {
                    try fm.moveItem(at: oldDir, to: attachmentDir)
                    movedFrom = oldDir
                }
            }

            var failed: [String] = []
            if let audioURL, !(await attach(audioURL, into: attachmentDir)) {
                failed.append(audioURL.path)
            }

            let files = Self.attachmentFiles(in: attachmentDir)
            let content: String
            if full {
                let note = CaptureContract.Note(
                    capturedAt: capturedAt,
                    source: .raptureIOS,
                    type: .meeting,
                    rawMedia: nil,
                    body: meeting.body,
                    rawBody: nil,
                    meetingId: meeting.header.meetingId
                )
                content = CaptureContract.compose(note, attachments: files.map {
                    CaptureContract.FooterAttachment(folder: attachmentName, filename: $0)
                })
            } else {
                content = FileWriter.composeBody(text: rawText, copiedAttachments: files.map {
                    (folder: attachmentName, filename: $0)
                })
            }

            do {
                if let existing = existingNote, existing.standardizedFileURL != noteURL.standardizedFileURL {
                    // New text in place first, then one rename: at no point do
                    // two copies of the meeting exist side by side.
                    try AtomicFile.write(Data(content.utf8), to: existing)
                    try fm.moveItem(at: existing, to: noteURL)
                } else {
                    try AtomicFile.write(Data(content.utf8), to: noteURL)
                }
            } catch {
                // Put the attachment folder back so the old note's links hold.
                if let movedFrom {
                    try? fm.moveItem(at: attachmentDir, to: movedFrom)
                }
                throw error
            }
            return WriteResult(outcome: .success(noteURL), failedAttachments: failed)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Meeting filing failed for \(relayBaseName, privacy: .public): \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    // MARK: - Late audio

    /// Adds relay audio to an already-filed meeting note (the transcript part
    /// arrived after its summary, or its audio synced late) and rebuilds the
    /// note's footer. The note's text is otherwise untouched.
    func attachAudio(_ audioURL: URL, toNote note: URL, in folder: URL) async -> WriteResult {
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        let attachmentDir = note.deletingPathExtension()
        guard RelayFiler.isUsableAttachmentDirectory(attachmentDir) else {
            return WriteResult(outcome: .failure(reason: "Couldn't attach audio to \(note.lastPathComponent)"), failedAttachments: [audioURL.path])
        }
        guard await attach(audioURL, into: attachmentDir) else {
            return WriteResult(outcome: .failure(reason: "Couldn't copy audio file \(audioURL.lastPathComponent)"), failedAttachments: [audioURL.path])
        }
        do {
            let text = String(decoding: try Data(contentsOf: note), as: UTF8.self)
            let folderName = attachmentDir.lastPathComponent
            let files = Self.attachmentFiles(in: attachmentDir)
            let updated = Self.replacingFooter(in: text, isMarkdown: note.pathExtension == "md", folder: folderName, files: files)
            try AtomicFile.write(Data(updated.utf8), to: note)
            return WriteResult(outcome: .success(note), failedAttachments: [])
        } catch {
            return WriteResult(outcome: .failure(reason: error.localizedDescription), failedAttachments: [])
        }
    }

    // MARK: - Locate

    /// The meeting's note: the recorded path while it still exists, else a scan
    /// for the id (the user may have renamed or moved the note within the
    /// folder, or state.json may have been reset). Scans `Meetings/*.md` for
    /// `meeting_id:` frontmatter and root `*.txt` for the raw-mode marker.
    nonisolated static func locateNote(meetingId: String, recordedPath: String?, in folder: URL) -> URL? {
        let fm = FileManager.default
        if let recordedPath, !recordedPath.isEmpty {
            let url = folder.appendingPathComponent(recordedPath)
            if fm.fileExists(atPath: url.path), !isDirectory(url) { return url }
        }
        let meetingsDir = folder.appendingPathComponent(CaptureType.meeting.subfolder, isDirectory: true)
        for url in files(in: meetingsDir, ext: "md") where frontmatterMeetingId(of: url) == meetingId {
            return url
        }
        for url in files(in: folder, ext: "txt") where MeetingMarker.peek(fileAt: url)?.meetingId == meetingId {
            return url
        }
        return nil
    }

    // MARK: - Pure helpers

    /// True when `name` is `base` or `base-N` (a collision suffix from an
    /// earlier write of the same title).
    nonisolated static func baseMatches(_ name: String, base: String) -> Bool {
        if name == base { return true }
        guard name.hasPrefix(base + "-") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Strips a well-formed trailing footer (either format) and appends one
    /// listing `files`. With no files the footer is simply dropped.
    nonisolated static func replacingFooter(in text: String, isMarkdown: Bool, folder: String, files: [String]) -> String {
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

    // MARK: - I/O helpers

    /// Copies relay audio into the attachment folder. Already present (same
    /// name) counts as attached, so a retry never duplicates the file.
    private func attach(_ audioURL: URL, into dir: URL) async -> Bool {
        let fm = FileManager.default
        let filename = FileWriter.sanitizeAttachmentFilename(audioURL.lastPathComponent)
        let destination = dir.appendingPathComponent(filename)
        if fm.fileExists(atPath: destination.path) { return true }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        if await RelayFiler.copyWithRetry(from: audioURL, to: destination) { return true }
        FileSafety.removeIfEmpty(dir)
        return false
    }

    nonisolated static func attachmentFiles(in dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") && !isDirectory(dir.appendingPathComponent($0)) }
            .sorted()
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private nonisolated static func files(in dir: URL, ext: String) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == ext }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// The `meeting_id` value from a note's YAML frontmatter, canonicalized.
    nonisolated static func frontmatterMeetingId(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2048) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { return nil }
            if line.hasPrefix("meeting_id:") {
                let value = line.dropFirst("meeting_id:".count).trimmingCharacters(in: .whitespaces)
                return MeetingMarker.canonicalId(value)
            }
        }
        return nil
    }
}
