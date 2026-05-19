import Foundation
import OSLog

@MainActor
final class FileWriter {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "FileWriter")
    static let attachmentRetryDelay: TimeInterval = 2

    func write(_ captured: CapturedMessage, to folder: URL) async -> WriteResult {
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
                    try? FileManager.default.removeItem(at: attachmentFolderURL)
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

    private nonisolated static func baseName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private nonisolated static func uniqueDestination(in folder: URL, baseName: String) -> (URL, String) {
        var candidate = baseName
        var suffix = 1
        while true {
            let txt = folder.appendingPathComponent(candidate + ".txt")
            let dir = folder.appendingPathComponent(candidate, isDirectory: true)
            let txtExists = FileManager.default.fileExists(atPath: txt.path)
            let dirExists = FileManager.default.fileExists(atPath: dir.path)
            if !txtExists && !dirExists {
                return (txt, candidate)
            }
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
    }

    private nonisolated static func composeBody(text: String, copiedAttachments: [(folder: String, filename: String)]) -> String {
        guard !copiedAttachments.isEmpty else { return text }
        let lines = copiedAttachments.map { "- \($0.folder)/\($0.filename)" }
        let separator = text.isEmpty ? "" : "\n\n"
        return "\(text)\(separator)Attachments:\n" + lines.joined(separator: "\n") + "\n"
    }

    private enum AttachmentCopyResult {
        case success(filename: String)
        case failure(sourcePath: String)
    }

    private nonisolated static func copyAttachment(
        _ attachment: AttachmentRef,
        to destinationFolder: URL
    ) async -> AttachmentCopyResult {
        let sourceURL = URL(fileURLWithPath: attachment.sourcePath)
        let filename = attachment.transferName ?? sourceURL.lastPathComponent
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
    func copyItem(at source: URL, to destination: URL, ifSourceExists: Bool) -> Bool {
        guard fileExists(atPath: source.path) else { return false }
        do {
            try copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
