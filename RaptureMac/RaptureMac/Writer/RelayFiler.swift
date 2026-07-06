import Foundation
import OSLog

/// Seam so `RelayProcessor` tests can substitute a fake filer.
protocol RelayFiling: Sendable {
    @MainActor func file(_ candidate: RelayCandidate, to folder: URL) async -> WriteResult
    @MainActor func fileOrphanAudio(at url: URL, to folder: URL) async -> WriteResult
}

/// Files relay arrivals into the output folder using `FileWriter`'s conventions:
/// the same collision walk, atomic writes, attachment sibling folder, sanitization,
/// and Attachments footer. Unlike `FileWriter`, the output basename is the relay
/// basename verbatim (`<timestamp> <title>`): the iPhone already writes names in
/// the Rapture Notes convention, and the note body lands untransformed.
@MainActor
final class RelayFiler: RelayFiling {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "RelayFiler")
    static let audioRetryDelay: TimeInterval = 2

    func file(_ candidate: RelayCandidate, to folder: URL) async -> WriteResult {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let data = try Data(contentsOf: candidate.txtURL)
            // Lossy decode: a malformed byte sequence files with replacement
            // characters rather than crashing or stalling the relay forever.
            let text = String(decoding: data, as: UTF8.self)

            let (txtURL, attachmentFolderName) = FileWriter.uniqueDestination(in: folder, baseName: candidate.baseName)
            let attachmentFolderURL = folder.appendingPathComponent(attachmentFolderName, isDirectory: true)

            var failedAttachments: [String] = []
            var copiedAttachments: [(folder: String, filename: String)] = []

            if let audioURL = candidate.audioURL {
                try FileManager.default.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
                let filename = FileWriter.sanitizeAttachmentFilename(audioURL.lastPathComponent)
                if await Self.copyWithRetry(from: audioURL, to: attachmentFolderURL.appendingPathComponent(filename)) {
                    copiedAttachments.append((folder: attachmentFolderName, filename: filename))
                } else {
                    failedAttachments.append(audioURL.path)
                    // Every copy failed, so the folder we just created is empty; the
                    // guarded primitive removes it and never a folder with data.
                    FileSafety.removeIfEmpty(attachmentFolderURL)
                }
            }

            let body = FileWriter.composeBody(text: text, copiedAttachments: copiedAttachments)
            try AtomicFile.write(Data(body.utf8), to: txtURL)

            return WriteResult(outcome: .success(txtURL), failedAttachments: failedAttachments)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Relay filing failed for \(candidate.relayFilename, privacy: .public): \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    /// Files an `.m4a` whose note is gone (filed text-only before the audio synced,
    /// or never existed). It lands in the sibling attachment folder its note's
    /// Attachments footer would have pointed to; the filed note is never rewritten.
    func fileOrphanAudio(at url: URL, to folder: URL) async -> WriteResult {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let baseName = url.deletingPathExtension().lastPathComponent
            let directory = Self.uniqueDirectory(in: folder, baseName: baseName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let filename = FileWriter.sanitizeAttachmentFilename(url.lastPathComponent)
            let destination = directory.appendingPathComponent(filename)
            if await Self.copyWithRetry(from: url, to: destination) {
                return WriteResult(outcome: .success(destination), failedAttachments: [])
            }
            FileSafety.removeIfEmpty(directory)
            return WriteResult(outcome: .failure(reason: "Couldn't copy audio file \(url.lastPathComponent)"), failedAttachments: [url.path])
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Orphan audio filing failed for \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    /// Directory-only collision walk: unlike `FileWriter.uniqueDestination`, an
    /// existing `<base>.txt` is *not* a collision, because that is exactly the filed
    /// note the orphan audio belongs next to.
    nonisolated static func uniqueDirectory(in folder: URL, baseName: String) -> URL {
        var candidate = baseName
        var suffix = 1
        while true {
            let dir = folder.appendingPathComponent(candidate, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                return dir
            }
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
    }

    /// Same one-retry convention as `FileWriter.copyAttachment`: iCloud may still be
    /// settling the file, so a failed copy gets one more chance after a short delay.
    private nonisolated static func copyWithRetry(from source: URL, to destination: URL) async -> Bool {
        if copyIfSourceExists(from: source, to: destination) { return true }
        try? await Task.sleep(for: .seconds(audioRetryDelay))
        return copyIfSourceExists(from: source, to: destination)
    }

    private nonisolated static func copyIfSourceExists(from source: URL, to destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
