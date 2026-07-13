import Foundation
import OSLog

/// Seam so `RelayProcessor` tests can substitute a fake filer.
protocol RelayFiling: Sendable {
    @MainActor func file(_ candidate: RelayCandidate, to folder: URL, mode: TriageMode) async -> WriteResult
    @MainActor func fileOrphanAudio(at url: URL, to folder: URL, preferredDirectory: URL?) async -> WriteResult
}

/// Files relay arrivals into the output folder using `FileWriter`'s conventions:
/// the same collision walk, atomic writes, attachment sibling folder, sanitization,
/// and footer. In `.full` mode the arrival becomes a contract Markdown note (the
/// iOS-derived title part of the relay basename is reused, so iPhone titles
/// survive); in `.raw` mode the pre-triage behavior is unchanged — the output
/// basename is the relay basename verbatim and the body lands untransformed.
@MainActor
final class RelayFiler: RelayFiling {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "RelayFiler")
    static let audioRetryDelay: TimeInterval = 2

    private let destinationGuard: DestinationGuard

    init(destinationGuard: DestinationGuard = DestinationGuard()) {
        self.destinationGuard = destinationGuard
    }

    func file(_ candidate: RelayCandidate, to folder: URL, mode: TriageMode) async -> WriteResult {
        // Never write toward an unplugged volume (shadow-folder guard); the relay
        // copy stays in the relay folder and the next scan retries.
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        switch mode {
        case .raw:
            return await fileRaw(candidate, to: folder)
        case .full:
            return await fileTriaged(candidate, to: folder)
        }
    }

    private func fileRaw(_ candidate: RelayCandidate, to folder: URL) async -> WriteResult {
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

    /// Compose-direct triage of a relay arrival: one write, straight to the final
    /// contract note in its classified subfolder. Title precedence: the iOS-derived
    /// relay title, else the deterministic derivation from the body.
    private func fileTriaged(_ candidate: RelayCandidate, to folder: URL) async -> WriteResult {
        do {
            let data = try Data(contentsOf: candidate.txtURL)
            let text = String(decoding: data, as: UTF8.self)

            let classification = TriageClassifier.classify(text)
            let title = TitleDeriver.relayTitle(fromBaseName: candidate.baseName)
                ?? (classification.type == .voiceNote
                    ? TitleDeriver.voiceNoteTitle(from: text)
                    : TitleDeriver.linkTitle(for: classification.rawMedia ?? "", type: classification.type))
            // The relay filename carries the capture instant; filing time is the
            // honest fallback for non-contract names.
            let capturedAt = RelayWatcher.parseRelayTimestamp(candidate.relayFilename) ?? Date()

            let subfolder = folder.appendingPathComponent(classification.type.subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

            let base = CaptureContract.filenameBase(title: title, capturedAt: capturedAt)
            let (mdURL, attachmentFolderName) = FileWriter.uniqueDestination(in: subfolder, baseName: base, fileExtension: "md")
            let attachmentFolderURL = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)

            var failedAttachments: [String] = []
            var copied: [CaptureContract.FooterAttachment] = []

            if let audioURL = candidate.audioURL {
                try FileManager.default.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
                let filename = FileWriter.sanitizeAttachmentFilename(audioURL.lastPathComponent)
                if await Self.copyWithRetry(from: audioURL, to: attachmentFolderURL.appendingPathComponent(filename)) {
                    copied.append(CaptureContract.FooterAttachment(folder: attachmentFolderName, filename: filename))
                } else {
                    failedAttachments.append(audioURL.path)
                    FileSafety.removeIfEmpty(attachmentFolderURL)
                }
            }

            let note = CaptureContract.Note(
                capturedAt: capturedAt,
                source: .raptureIOS,
                type: classification.type,
                rawMedia: classification.rawMedia,
                body: text,
                rawBody: nil
            )
            try AtomicFile.write(Data(CaptureContract.compose(note, attachments: copied).utf8), to: mdURL)

            return WriteResult(outcome: .success(mdURL), failedAttachments: failedAttachments)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Relay triage filing failed for \(candidate.relayFilename, privacy: .public): \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    /// Files an `.m4a` whose note is gone (filed text-only before the audio synced,
    /// or never existed). With `preferredDirectory` (the filed note's own attachment
    /// folder, looked up from the triage ledger) the audio lands next to its note;
    /// otherwise it lands in a root folder named after the relay basename — the
    /// pre-triage behavior. The filed note is never rewritten.
    func fileOrphanAudio(at url: URL, to folder: URL, preferredDirectory: URL?) async -> WriteResult {
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let directory: URL
            if let preferred = preferredDirectory, Self.isUsableAttachmentDirectory(preferred) {
                // The note's own attachment folder: an existing directory is the
                // target, never a collision.
                directory = preferred
            } else {
                let baseName = url.deletingPathExtension().lastPathComponent
                directory = Self.uniqueDirectory(in: folder, baseName: baseName)
            }
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

    /// A preferred attachment directory is usable when the path is free or already a
    /// directory; an existing *file* at the path falls back to the legacy placement.
    nonisolated static func isUsableAttachmentDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return !exists || isDir.boolValue
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
