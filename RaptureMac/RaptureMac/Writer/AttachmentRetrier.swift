import Foundation
import OSLog

/// Retries iMessage attachments that were not downloaded yet when their note
/// filed (the writer gives each one only a 2-second second chance). Photos and
/// videos from iCloud can take minutes. Each retry that lands copies the file
/// into the note's attachment folder and rebuilds the note's footer; the
/// history records the outcome either way.
///
/// In memory only: a quit cancels pending retries (the Activity history keeps
/// the "missing" entry, so the user still knows).
@MainActor
final class AttachmentRetrier {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AttachmentRetrier")

    /// Delays before each retry, from filing time.
    nonisolated static let schedule: [TimeInterval] = [30, 120, 600, 1800]

    private let appState: AppState
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var tasks: [URL: Task<Void, Never>] = [:]

    init(
        appState: AppState,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.appState = appState
        self.sleep = sleep
    }

    func schedule(noteURL: URL, attachments: [AttachmentRef]) {
        guard !attachments.isEmpty else { return }
        tasks[noteURL]?.cancel()
        tasks[noteURL] = Task { [weak self] in
            var remaining = attachments
            var waited: TimeInterval = 0
            for delay in Self.schedule {
                await self?.sleep(delay - waited)
                waited = delay
                guard !Task.isCancelled, let self else { return }
                remaining = await self.attempt(noteURL: noteURL, attachments: remaining)
                if remaining.isEmpty { break }
            }
            self?.finish(noteURL: noteURL, remaining: remaining, total: attachments.count)
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// One pass: copies what is now available. Returns what is still missing.
    /// Runs under the capture gate so a relocation can't move the note mid-copy.
    func attempt(noteURL: URL, attachments: [AttachmentRef]) async -> [AttachmentRef] {
        await appState.captureGate.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: noteURL.path) else { return attachments }
            let dir = noteURL.deletingPathExtension()
            var still: [AttachmentRef] = []
            var copiedAny = false
            for attachment in attachments {
                let source = URL(fileURLWithPath: attachment.sourcePath)
                let name = FileWriter.sanitizeAttachmentFilename(attachment.transferName ?? source.lastPathComponent)
                let destination = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { still.append(attachment); continue }
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: destination.path) {
                        try fm.copyItem(at: source, to: destination)
                    }
                    copiedAny = true
                } catch {
                    still.append(attachment)
                }
            }
            if copiedAny {
                do {
                    let text = String(decoding: try Data(contentsOf: noteURL), as: UTF8.self)
                    let updated = NoteFooter.replacing(
                        in: text, isMarkdown: noteURL.pathExtension == "md",
                        folder: dir.lastPathComponent, files: NoteFooter.attachmentFiles(in: dir))
                    try AtomicFile.write(Data(updated.utf8), to: noteURL)
                } catch {
                    Self.log.error("footer rewrite failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return still
        }
    }

    private func finish(noteURL: URL, remaining: [AttachmentRef], total: Int) {
        tasks[noteURL] = nil
        let name = noteURL.deletingPathExtension().lastPathComponent
        if remaining.isEmpty {
            appState.clearError(source: .attachments)
            appState.activity.record(.attachmentRecovered, source: .iMessage, "Missing \(total == 1 ? "attachment" : "attachments") added to \(name)", path: noteURL)
        } else {
            let files = remaining.map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent }.joined(separator: ", ")
            let message = "\(remaining.count) \(remaining.count == 1 ? "attachment" : "attachments") never downloaded for \(name): \(files)"
            appState.recordError(message, source: .attachments)
            appState.activity.record(.attachmentMissing, source: .iMessage, message, path: noteURL)
        }
    }
}
