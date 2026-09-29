import Foundation
import OSLog

/// Retries iMessage attachments that were not downloaded yet when their note
/// filed (the writer gives each one only a 2-second second chance). Photos and
/// videos from iCloud can take minutes. Each retry that lands copies the file
/// into the note's attachment folder and rebuilds the note's footer; the
/// history records the outcome either way.
///
/// Pending work is saved in `state.json` (`pendingAttachmentRetries`), so a
/// quit or restart resumes it: `resume()` picks up each note at the retry
/// times that are still ahead, counted from when the note filed.
@MainActor
final class AttachmentRetrier {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AttachmentRetrier")

    /// Delays before each retry, from filing time.
    nonisolated static let schedule: [TimeInterval] = [30, 120, 600, 1800]

    private let appState: AppState
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let clock: @Sendable () -> Date
    private var tasks: [URL: Task<Void, Never>] = [:]

    init(
        appState: AppState,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.sleep = sleep
        self.clock = clock
    }

    func schedule(noteURL: URL, attachments: [AttachmentRef]) {
        guard !attachments.isEmpty else { return }
        let entry = PendingAttachmentRetry(notePath: noteURL.path, attachments: attachments, firstAt: clock())
        persist(entry)
        start(entry)
    }

    /// Restarts every saved retry (call once capture has Full Disk Access,
    /// since Messages attachments live under ~/Library/Messages).
    func resume() {
        for entry in appState.state.state.pendingAttachmentRetries {
            start(entry)
        }
    }

    private func start(_ entry: PendingAttachmentRetry) {
        let noteURL = URL(fileURLWithPath: entry.notePath)
        tasks[noteURL]?.cancel()
        tasks[noteURL] = Task { [weak self] in
            guard let self else { return }
            var remaining = entry.attachments
            // Only the retry times still ahead; a resume long after filing
            // gets one last try right away.
            let elapsed = self.clock().timeIntervalSince(entry.firstAt)
            var ahead = Self.schedule.filter { $0 > elapsed }
            if ahead.isEmpty { ahead = [elapsed] }
            var waited = elapsed
            for delay in ahead {
                await self.sleep(max(0, delay - waited))
                waited = delay
                guard !Task.isCancelled else { return }
                remaining = await self.attempt(noteURL: noteURL, attachments: remaining)
                if remaining.isEmpty { break }
                self.persist(PendingAttachmentRetry(notePath: entry.notePath, attachments: remaining, firstAt: entry.firstAt))
            }
            guard !Task.isCancelled else { return }
            self.finish(noteURL: noteURL, remaining: remaining, total: entry.attachments.count)
        }
    }

    private func persist(_ entry: PendingAttachmentRetry) {
        appState.state.update { state in
            state.pendingAttachmentRetries.removeAll { $0.notePath == entry.notePath }
            state.pendingAttachmentRetries.append(entry)
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
        appState.state.update { state in
            state.pendingAttachmentRetries.removeAll { $0.notePath == noteURL.path }
        }
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
