import Foundation
import OSLog

/// Seam so `DestinationMonitor` tests can substitute a fake flusher.
protocol SpoolFiling: Sendable {
    @MainActor func file(_ item: SpoolItem, to folder: URL, mode: TriageMode) async -> WriteResult
}

/// Files a spooled capture into the destination using `FileWriter`'s conventions:
/// the same collision walk, atomic writes, attachment sibling folder, and footer.
/// The note's `captured`/`source` frontmatter and filename date come **verbatim
/// from the item's metadata** — nothing is re-inferred from spool file names or
/// mtimes, so a note flushed days late is indistinguishable from one written the
/// moment it was dictated.
@MainActor
final class SpoolFlusher: SpoolFiling {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SpoolFlusher")

    private let destinationGuard: DestinationGuard

    init(destinationGuard: DestinationGuard = DestinationGuard()) {
        self.destinationGuard = destinationGuard
    }

    func file(_ item: SpoolItem, to folder: URL, mode: TriageMode) async -> WriteResult {
        // The volume can vanish again mid-flush; never write toward it.
        guard destinationGuard.check(folder) != .volumeAbsent else {
            return WriteResult(outcome: .unavailable, failedAttachments: [])
        }
        do {
            let data = try Data(contentsOf: item.captureTextURL)
            let text = String(decoding: data, as: UTF8.self)
            switch mode {
            case .raw:
                return try fileRaw(item, text: text, to: folder)
            case .full:
                return try fileTriaged(item, text: text, to: folder)
            }
        } catch {
            let reason = error.localizedDescription
            Self.log.error("Spool flush failed for \(item.name, privacy: .public): \(reason, privacy: .public)")
            return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
        }
    }

    /// Raw escape-hatch mode: plain `.txt` at the destination root under the
    /// ISO-timestamp basename — byte-compatible with a live `FileWriter.writeRaw`.
    private func fileRaw(_ item: SpoolItem, text: String, to folder: URL) throws -> WriteResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let baseName = FileWriter.baseName(for: item.metadata.capturedAt)
        let (txtURL, attachmentFolderName) = FileWriter.uniqueDestination(in: folder, baseName: baseName)
        let attachmentFolderURL = folder.appendingPathComponent(attachmentFolderName, isDirectory: true)

        let copyOutcome = try copyAttachments(of: item, into: attachmentFolderURL)
        let copied = copyOutcome.copied.map { (folder: attachmentFolderName, filename: $0) }

        let body = FileWriter.composeBody(text: text, copiedAttachments: copied)
        try AtomicFile.write(Data(body.utf8), to: txtURL)

        return WriteResult(outcome: .success(txtURL), failedAttachments: copyOutcome.failed)
    }

    /// Full triage mode: compose-direct to the final contract note in its
    /// classified subfolder, exactly like a live `FileWriter.writeTriaged`.
    private func fileTriaged(_ item: SpoolItem, text: String, to folder: URL) throws -> WriteResult {
        let classification = TriageClassifier.classify(text)
        let title: String
        if classification.type == .voiceNote {
            title = TitleDeriver.voiceNoteTitle(from: text)
        } else {
            title = TitleDeriver.linkTitle(for: classification.rawMedia ?? "", type: classification.type)
        }

        let subfolder = folder.appendingPathComponent(classification.type.subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let base = CaptureContract.filenameBase(title: title, capturedAt: item.metadata.capturedAt)
        let (mdURL, attachmentFolderName) = FileWriter.uniqueDestination(in: subfolder, baseName: base, fileExtension: "md")
        let attachmentFolderURL = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)

        let copyOutcome = try copyAttachments(of: item, into: attachmentFolderURL)
        let copied = copyOutcome.copied.map {
            CaptureContract.FooterAttachment(folder: attachmentFolderName, filename: $0)
        }

        let note = CaptureContract.Note(
            capturedAt: item.metadata.capturedAt,
            source: item.metadata.source,
            type: classification.type,
            rawMedia: classification.rawMedia,
            body: text,
            rawBody: nil
        )
        try AtomicFile.write(Data(CaptureContract.compose(note, attachments: copied).utf8), to: mdURL)

        return WriteResult(outcome: .success(mdURL), failedAttachments: copyOutcome.failed)
    }

    /// Copies the item's spooled attachments (already sanitized at spool time)
    /// into the note's sibling folder, deterministically ordered. `failed` carries
    /// both fresh copy failures and the sources that already failed at spool time,
    /// so the caller's "attachments missing" reporting stays honest.
    private func copyAttachments(
        of item: SpoolItem,
        into attachmentFolderURL: URL
    ) throws -> (copied: [String], failed: [String]) {
        var failed = item.metadata.failedAttachments
        let sources = ((try? FileManager.default.contentsOfDirectory(
            at: item.attachmentsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !sources.isEmpty else { return ([], failed) }

        try FileManager.default.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
        var copied: [String] = []
        for source in sources {
            let filename = source.lastPathComponent
            do {
                try FileManager.default.copyItem(at: source, to: attachmentFolderURL.appendingPathComponent(filename))
                copied.append(filename)
            } catch {
                failed.append(source.path)
            }
        }
        if copied.isEmpty {
            // Every copy failed; the guarded primitive removes the empty folder.
            FileSafety.removeIfEmpty(attachmentFolderURL)
        }
        return (copied, failed)
    }
}
