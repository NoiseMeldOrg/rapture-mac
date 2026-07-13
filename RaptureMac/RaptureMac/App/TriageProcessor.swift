import Foundation
import OSLog

/// Consumes `TriageWatcher` batches: converts each settled external `.txt` at the
/// destination root into its contract Markdown note. Fourth actor on the output
/// tree, so every file is processed under `appState.captureGate` — per **file**,
/// not per batch: a large backlog drain interleaves with live iMessage/relay
/// batches instead of starving them (the gate is FIFO, snapshots re-derivable).
///
/// Per-file order is read → compose → write `.md` → move attachment folder →
/// record ledger → delete source. The delete is the app's only file deletion
/// inside the user's destination, and it is legal only because the source's full
/// content was durably written into a note verified in the same operation (a
/// ledger hit likewise drains its source only while the recorded note still
/// exists — a re-dropped source whose note was deleted re-triages instead).
@MainActor
final class TriageProcessor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "TriageProcessor")

    /// A persistent failure must not re-report every poll tick; each failed name
    /// waits this long before retrying. Same rationale as `RelayProcessor`.
    nonisolated static let failureRetryBackoff: TimeInterval = 60

    /// Sanity cap: a capture is dictated or typed text; anything this large is not
    /// a note. Reported once and left in place, never deleted.
    nonisolated static let maxTxtBytes = 10 * 1024 * 1024

    private let appState: AppState
    private let ledger: TriageLedger
    private let destinationGuard: DestinationGuard
    /// Reminders/Calendar handoff, fired once per freshly-triaged note (never
    /// on ledger-hit ghost drains). Silent — hand-drops have no reply path.
    private let handoff: (any HandoffProcessing)?
    private let clock: @Sendable () -> Date
    /// Test override; nil means "read the CURRENT zone at each use", matching the
    /// writers (a system time-zone change mid-run must not date backlog notes with
    /// a zone captured at startup).
    private let timeZoneOverride: TimeZone?

    private var lastFailureAt: [String: Date] = [:]
    private var reportedOversized: Set<String> = []

    init(
        appState: AppState,
        ledger: TriageLedger,
        destinationGuard: DestinationGuard = DestinationGuard(),
        handoff: (any HandoffProcessing)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone? = nil
    ) {
        self.appState = appState
        self.ledger = ledger
        self.destinationGuard = destinationGuard
        self.handoff = handoff
        self.clock = clock
        self.timeZoneOverride = timeZone
    }

    /// Pure backoff decision, testable without a processor.
    nonisolated static func shouldAttempt(name: String, lastFailureAt: [String: Date], now: Date) -> Bool {
        guard let last = lastFailureAt[name] else { return true }
        return now.timeIntervalSince(last) >= failureRetryBackoff
    }

    func process(batch: TriageScanBatch) async {
        let total = batch.candidates.count
        var done = 0
        for candidate in batch.candidates {
            // Never overwrite a mid-drain mode flip: the watcher posts .off exactly
            // once (its dedup won't re-post), so clobbering it here would leave the
            // UI claiming the engine is active after the user disabled it.
            if total > 1, appState.triageStatus != .off {
                appState.triageStatus = .triaging(done: done, total: total)
            }
            await appState.captureGate.withLock {
                await self.processLocked(candidate)
            }
            done += 1
        }
        if total > 1, case .triaging = appState.triageStatus {
            // Reset only our own progress display; never clobber a mode flip (.off)
            // the watcher posted mid-drain.
            appState.triageStatus = .watching
        }
    }

    private func processLocked(_ candidate: TriageCandidate) async {
        // Re-read everything inside the lock: unlike the relay folder, the watched
        // folder is the thing that relocates, and the mode may have flipped since
        // the snapshot. Deferral is free — the next scan re-delivers.
        let settings = appState.settings.settings
        guard !settings.paused, !appState.isRelocating,
              settings.triageMode == .full,
              let folder = settings.outputFolder else { return }

        // TOCTOU shadow-folder guard: the volume can unplug between the watcher's
        // scan and this lock; the mkdir below must never run against an absent
        // volume. Sources live on that volume anyway — deferral is free.
        guard destinationGuard.check(folder) != .volumeAbsent else { return }

        let name = candidate.filename
        // Stale-snapshot guard: a candidate from a pre-relocation scan points at
        // the old root; a vanished file simply isn't work anymore.
        let sourceURL = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        guard Self.shouldAttempt(name: name, lastFailureAt: lastFailureAt, now: clock()) else { return }

        if let size = fileSize(of: sourceURL), size > Self.maxTxtBytes {
            if !reportedOversized.contains(name) {
                reportedOversized.insert(name)
                recordTriageError("\(name) is too large to triage automatically")
            }
            return
        }

        // Read off the main actor: a dataless File-Provider file blocks the read
        // until its download completes, and that wait must not freeze the UI.
        // Task.detached rather than an inherited Task because the synchronous read
        // is the entire body and must not start on the main actor.
        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: sourceURL)
            }.value
        } catch {
            fail(name: name, reason: "Couldn't read \(name): \(error.localizedDescription)")
            return
        }

        let hash = TriageLedger.hash(of: data)
        if let entry = ledger.entry(sourceFilename: name, contentHash: hash) {
            let noteURL = folder.appendingPathComponent(entry.mdRelativePath)
            if FileManager.default.fileExists(atPath: noteURL.path) {
                // Sync ghost of an already-triaged capture: drain it. Safe only
                // because the note it became still exists.
                removeSource(sourceURL)
                return
            }
            // The note is gone (user deleted it) and the source is back: re-triage.
        }

        let text = String(decoding: data, as: UTF8.self)

        // Conservative footer rule: a trailing Attachments block counts only when a
        // referenced sibling folder actually exists on disk; otherwise the block is
        // body text and is preserved verbatim.
        var bodyText = text
        var sourceAttachmentFolder: URL?
        var footerFilenames: [String] = []
        if let footer = CaptureContract.parseFooter(text) {
            // Sorted so a (hand-authored) multi-folder footer picks deterministically
            // across launches; app-written footers only ever reference one folder.
            let folders = Set(footer.attachments.map(\.folder)).sorted()
            if let existing = folders.first(where: {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) {
                bodyText = footer.bodyWithoutFooter
                sourceAttachmentFolder = folder.appendingPathComponent(existing, isDirectory: true)
                footerFilenames = footer.attachments.filter { $0.folder == existing }.map(\.filename)
            }
        }

        let info = CaptureContract.parseSourceFilename(name)
        let capturedAt = info.capturedAt ?? modificationDate(of: sourceURL) ?? clock()
        let classification = TriageClassifier.classify(bodyText)
        let title = info.relayTitle
            ?? (classification.type == .voiceNote
                ? TitleDeriver.voiceNoteTitle(from: bodyText)
                : TitleDeriver.linkTitle(for: classification.rawMedia ?? "", type: classification.type))

        do {
            let subfolder = folder.appendingPathComponent(classification.type.subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let base = CaptureContract.filenameBase(title: title, capturedAt: capturedAt, timeZone: timeZoneOverride ?? .current)
            let (mdURL, attachmentFolderName) = FileWriter.uniqueDestination(in: subfolder, baseName: base, fileExtension: "md")

            var attachments: [CaptureContract.FooterAttachment] = []
            if let sourceAttachmentFolder {
                // Move (not copy): same volume, atomic, and the folder must follow
                // its note so the rewritten footer links stay valid.
                let destination = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)
                try FileManager.default.moveItem(at: sourceAttachmentFolder, to: destination)
                attachments = footerFilenames.map {
                    CaptureContract.FooterAttachment(folder: attachmentFolderName, filename: $0)
                }
            }

            let note = CaptureContract.Note(
                capturedAt: capturedAt,
                source: info.source,
                type: classification.type,
                rawMedia: classification.rawMedia,
                body: bodyText,
                rawBody: nil
            )
            do {
                try AtomicFile.write(Data(CaptureContract.compose(note, attachments: attachments).utf8), to: mdURL)
            } catch {
                // Compensate: the attachment folder moved but the note write failed —
                // put it back so the next attempt sees an intact source.
                if let sourceAttachmentFolder {
                    let destination = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)
                    try? FileManager.default.moveItem(at: destination, to: sourceAttachmentFolder)
                }
                throw error
            }

            ledger.record(
                sourceFilename: name,
                contentHash: hash,
                mdRelativePath: CaptureContract.relativePath(of: mdURL, in: folder)
            )
            removeSource(sourceURL)
            lastFailureAt[name] = nil
            clearTriageError()
            Self.log.info("triaged \(name, privacy: .public) → \(mdURL.lastPathComponent, privacy: .public)")
            if let handoff {
                // Footer-stripped body (attachment links aren't prose); capturedAt
                // is the capture's own stamp — a backlog note saying "tomorrow"
                // anchors to when it was dictated, not to this drain.
                _ = await handoff.process(text: bodyText, capturedAt: capturedAt)
            }
        } catch {
            fail(name: name, reason: "Couldn't triage \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Direct file removal is deliberate and narrow: the one file the app ever
    /// deletes in the user's destination is a `.txt` whose full content was just
    /// durably written to a verified note. `FileSafety.removeIfEmpty` remains the
    /// app's only *directory*-delete primitive. A failed delete retries via the
    /// ledger-hit path next scan.
    private func removeSource(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.log.warning("couldn't remove triaged source \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fail(name: String, reason: String) {
        Self.log.error("\(reason, privacy: .public)")
        lastFailureAt[name] = clock()
        recordTriageError(reason)
    }

    private func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func recordTriageError(_ message: String) {
        appState.triageLastError = message
        appState.recordError(message)
    }

    private func clearTriageError() {
        guard appState.triageLastError != nil else { return }
        appState.triageLastError = nil
        if appState.lastError != nil {
            appState.clearError()
        }
    }
}
