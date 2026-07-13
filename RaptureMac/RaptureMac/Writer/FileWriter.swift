import Foundation
import OSLog

@MainActor
final class FileWriter {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "FileWriter")
    static let attachmentRetryDelay: TimeInterval = 2

    private let destinationGuard: DestinationGuard

    init(destinationGuard: DestinationGuard = DestinationGuard()) {
        self.destinationGuard = destinationGuard
    }

    func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult {
        // An unplugged destination volume must not be written to: createDirectory
        // below would otherwise fabricate a shadow folder on the boot volume.
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        switch mode {
        case .raw:
            return await writeRaw(captured, to: folder)
        case .full:
            return await writeTriaged(captured, to: folder)
        }
    }

    /// The pre-triage behavior, byte-identical: plain `.txt` at the destination root
    /// under the ISO-timestamp basename, with the plain-text Attachments footer.
    private func writeRaw(_ captured: CapturedMessage, to folder: URL) async -> WriteResult {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let baseName = Self.baseName(for: captured.event.dateUTC)
            let (txtURL, attachmentFolderName) = Self.uniqueDestination(in: folder, baseName: baseName)
            let attachmentFolderURL = folder.appendingPathComponent(attachmentFolderName, isDirectory: true)

            var failedAttachments: [String] = []
            var copiedAttachments: [(folder: String, filename: String)] = []

            if !captured.event.attachments.isEmpty {
                try FileManager.default.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
                for attachment in captured.event.attachments {
                    let result = await Self.copyAttachment(attachment, to: attachmentFolderURL)
                    switch result {
                    case .success(let filename):
                        copiedAttachments.append((folder: attachmentFolderName, filename: filename))
                    case .failure(let path):
                        failedAttachments.append(path)
                    }
                }
                if copiedAttachments.isEmpty {
                    // Every copy failed, so the folder we just created is empty; the
                    // guarded primitive removes it and never an output folder with data.
                    FileSafety.removeIfEmpty(attachmentFolderURL)
                }
            }

            let body = Self.composeBody(text: captured.decodedText, copiedAttachments: copiedAttachments)
            try AtomicFile.write(Data(body.utf8), to: txtURL)

            return WriteResult(outcome: .success(txtURL), failedAttachments: failedAttachments)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Write failed: \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    /// Compose-direct triage: the capture is written once, as its final Markdown note
    /// (contract frontmatter, classified subfolder, title-based filename). No transient
    /// `.txt` ever appears in the destination, so sync engines see one clean event.
    private func writeTriaged(_ captured: CapturedMessage, to folder: URL) async -> WriteResult {
        do {
            let text = captured.decodedText
            let classification = TriageClassifier.classify(text)
            let title: String
            if classification.type == .voiceNote {
                title = TitleDeriver.voiceNoteTitle(from: text)
            } else {
                title = TitleDeriver.linkTitle(for: classification.rawMedia ?? "", type: classification.type)
            }

            let subfolder = folder.appendingPathComponent(classification.type.subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

            let base = CaptureContract.filenameBase(title: title, capturedAt: captured.event.dateUTC)
            let (mdURL, attachmentFolderName) = Self.uniqueDestination(in: subfolder, baseName: base, fileExtension: "md")
            let attachmentFolderURL = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)

            var failedAttachments: [String] = []
            var copied: [CaptureContract.FooterAttachment] = []

            if !captured.event.attachments.isEmpty {
                try FileManager.default.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
                for attachment in captured.event.attachments {
                    let result = await Self.copyAttachment(attachment, to: attachmentFolderURL)
                    switch result {
                    case .success(let filename):
                        copied.append(CaptureContract.FooterAttachment(folder: attachmentFolderName, filename: filename))
                    case .failure(let path):
                        failedAttachments.append(path)
                    }
                }
                if copied.isEmpty {
                    FileSafety.removeIfEmpty(attachmentFolderURL)
                }
            }

            let note = CaptureContract.Note(
                capturedAt: captured.event.dateUTC,
                source: .raptureMac,
                type: classification.type,
                rawMedia: classification.rawMedia,
                body: text,
                rawBody: nil
            )
            let contents = CaptureContract.compose(note, attachments: copied)
            try AtomicFile.write(Data(contents.utf8), to: mdURL)

            return WriteResult(outcome: .success(mdURL), failedAttachments: failedAttachments)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Triage write failed: \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    // Internal (not private): `SpoolFlusher` reuses the raw-mode basename convention.
    nonisolated static func baseName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    // Internal (not private): `RelayFiler` reuses the same collision walk and
    // Attachments-footer conventions so both capture sources file identically.
    nonisolated static func uniqueDestination(in folder: URL, baseName: String) -> (URL, String) {
        uniqueDestination(in: folder, baseName: baseName, fileExtension: "txt")
    }

    nonisolated static func uniqueDestination(in folder: URL, baseName: String, fileExtension: String) -> (URL, String) {
        var candidate = baseName
        var suffix = 1
        while true {
            let file = folder.appendingPathComponent(candidate + "." + fileExtension)
            let dir = folder.appendingPathComponent(candidate, isDirectory: true)
            let fileExists = FileManager.default.fileExists(atPath: file.path)
            let dirExists = FileManager.default.fileExists(atPath: dir.path)
            if !fileExists && !dirExists {
                return (file, candidate)
            }
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
    }

    nonisolated static func composeBody(text: String, copiedAttachments: [(folder: String, filename: String)]) -> String {
        guard !copiedAttachments.isEmpty else { return text }
        let lines = copiedAttachments.map { "- \($0.folder)/\($0.filename)" }
        let separator = text.isEmpty ? "" : "\n\n"
        return "\(text)\(separator)Attachments:\n" + lines.joined(separator: "\n") + "\n"
    }

    private enum AttachmentCopyResult {
        case success(filename: String)
        case failure(sourcePath: String)
    }

    /// Strips path-traversal segments and separators from an attachment filename so
    /// adversarial `transfer_name` values can't write outside the output folder.
    nonisolated static func sanitizeAttachmentFilename(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "\0", with: "")
        let lastComponent = (stripped as NSString).lastPathComponent
        let noSeparators = lastComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = noSeparators.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "attachment"
        }
        return trimmed
    }

    private nonisolated static func copyAttachment(
        _ attachment: AttachmentRef,
        to destinationFolder: URL
    ) async -> AttachmentCopyResult {
        let sourceURL = URL(fileURLWithPath: attachment.sourcePath)
        let rawName = attachment.transferName ?? sourceURL.lastPathComponent
        let filename = sanitizeAttachmentFilename(rawName)
        let destURL = destinationFolder.appendingPathComponent(filename)

        if FileManager.default.copyItem(at: sourceURL, to: destURL, ifSourceExists: true) {
            return .success(filename: filename)
        }

        try? await Task.sleep(for: .seconds(attachmentRetryDelay))
        if FileManager.default.copyItem(at: sourceURL, to: destURL, ifSourceExists: true) {
            return .success(filename: filename)
        }

        return .failure(sourcePath: attachment.sourcePath)
    }
}

private extension FileManager {
    nonisolated func copyItem(at source: URL, to destination: URL, ifSourceExists: Bool) -> Bool {
        guard fileExists(atPath: source.path) else { return false }
        do {
            try copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
