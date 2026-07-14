import Foundation
import OSLog

/// The enrichment worker: an in-memory FIFO of link notes to enrich, drained
/// one job at a time in two phases — fetch with the capture gate NOT held
/// (network is slow; the pipeline must keep filing), then one gated mutation
/// pass (artifact write, real-title rename, `Media:` append, ledgers).
///
/// Strictly best-effort: the note is always already filed and complete before
/// a job exists. Quiet failure — brief retries, then silent give-up; trouble
/// surfaces only via `AppState.enrichmentLastError` (Settings), never the menu
/// bar. No persisted queue and no backfill: an app quit mid-job leaves the
/// note unenriched, by design (the "arrival window" is the job's lifetime).
@Observable
@MainActor
final class LinkEnrichmentService: LinkEnriching {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "LinkEnrichmentService")

    /// Whole-attempt ceiling (a YouTube attempt is up to 4 requests of 10s each;
    /// 20s bounds the worst case while staying "background" money).
    nonisolated static let attemptTimeout: TimeInterval = 20
    /// Transport-class attempts per job; content-class failures give up at once.
    nonisolated static let maxAttempts = 3
    /// After this many *consecutive* transport-failed jobs, pause fetching —
    /// a dead network must not burn 3×20s per link across a backlog drain.
    nonisolated static let cooldownThreshold = 2
    nonisolated static let failureCooldown: TimeInterval = 60
    /// Phase B deferral (paused / relocating / volume absent): retry cadence
    /// and total budget before the job drops silently.
    nonisolated static let deferRetryInterval: TimeInterval = 10
    nonisolated static let deferBudget: TimeInterval = 300

    struct Job {
        let fingerprint: String
        let echo: LinkNoteEcho
        /// Destination-relative note paths (stored relative so relocation
        /// mid-queue can't strand the job; resolved against the CURRENT folder
        /// inside the gate). Grows when a concurrent duplicate coalesces.
        var noteRelativePaths: [String]
        var attempts = 0
    }

    private let appState: AppState
    private let fetcher: any LinkFetching
    private let ledger: EnrichedLinkLedger
    private let triageLedger: TriageLedger
    private let destinationGuard: DestinationGuard
    private let clock: @Sendable () -> Date
    private let retrySpacing: [TimeInterval]
    private let sleeper: @Sendable (TimeInterval) async -> Void

    private(set) var queue: [Job] = []
    private var workerTask: Task<Void, Never>?
    private var consecutiveTransportFailures = 0
    private var cooldownUntil: Date?

    init(
        appState: AppState,
        fetcher: any LinkFetching,
        ledger: EnrichedLinkLedger,
        triageLedger: TriageLedger,
        destinationGuard: DestinationGuard = DestinationGuard(),
        clock: @escaping @Sendable () -> Date = { Date() },
        retrySpacing: [TimeInterval] = [30, 120],
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.appState = appState
        self.fetcher = fetcher
        self.ledger = ledger
        self.triageLedger = triageLedger
        self.destinationGuard = destinationGuard
        self.clock = clock
        self.retrySpacing = retrySpacing
        self.sleeper = sleeper
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
        queue.removeAll()
    }

    // MARK: - LinkEnriching (called by the four processors; never blocks)

    func noteFiled(noteURL: URL, in folder: URL, echo: LinkNoteEcho) {
        guard appState.settings.settings.linkEnrichmentEnabled else { return }
        guard let fingerprint = LinkFingerprint.fingerprint(rawMedia: echo.rawMedia, type: echo.type) else { return }
        let relativePath = CaptureContract.relativePath(of: noteURL, in: folder)

        // Coalesce a concurrent duplicate onto the queued/in-flight job: one
        // fetch services every note that captured the same link.
        if let index = queue.firstIndex(where: { $0.fingerprint == fingerprint }) {
            queue[index].noteRelativePaths.append(relativePath)
            return
        }
        queue.append(Job(fingerprint: fingerprint, echo: echo, noteRelativePaths: [relativePath]))
        ensureWorker()
    }

    /// Tests await queue drain deterministically (single-threaded main actor).
    func awaitIdle() async {
        while let task = workerTask {
            await task.value
        }
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { workerTask = nil }
        while !queue.isEmpty, !Task.isCancelled {
            if let until = cooldownUntil {
                let wait = until.timeIntervalSince(clock())
                if wait > 0 { await sleeper(wait) }
                cooldownUntil = nil
            }
            await processHead()
        }
    }

    /// One job, start to finish (including its retries and deferrals). The job
    /// stays at queue[0] throughout so concurrent captures keep coalescing onto
    /// it; leftovers that arrive after the mutation pass re-enqueue and hit the
    /// ledger (zero fetch).
    private func processHead() async {
        guard let job = queue.first else { return }

        // Dedup: a live ledger entry means the artifact already exists — no
        // fetch. If the recorded artifact was user-deleted, fall through to a
        // fresh fetch and refresh the entry.
        if let entry = ledger.entry(fingerprint: job.fingerprint) {
            let outcome = await mutateWithDeferrals(job: job, mode: .dedup(entry))
            if outcome != .artifactMissing {
                finishHead(servicedCount: job.noteRelativePaths.count)
                return
            }
        }

        while true {
            let fetched: FetchedLinkContent
            do {
                let currentFetcher = fetcher
                let echo = queue.first?.echo ?? job.echo
                fetched = try await AITriageService.withTimeout(Self.attemptTimeout) {
                    try await Self.fetch(echo: echo, fetcher: currentFetcher)
                }
            } catch {
                // stop() may have cleared the queue while the fetch was in flight.
                guard !queue.isEmpty else { return }
                let fetchError = Self.asFetchError(error)
                guard fetchError.isTransport else {
                    // Content-class: a retry can't fix it. Give up quietly.
                    giveUp(job: job, transport: false, message: Self.giveUpMessage(for: job.echo.type))
                    return
                }
                let attempts = queue[0].attempts + 1
                queue[0].attempts = attempts
                if attempts >= Self.maxAttempts {
                    giveUp(job: job, transport: true, message: Self.giveUpMessage(for: job.echo.type))
                    return
                }
                await sleeper(retrySpacing[min(attempts - 1, retrySpacing.count - 1)])
                continue
            }

            guard !queue.isEmpty else { return }
            consecutiveTransportFailures = 0
            let outcome = await mutateWithDeferrals(job: queue.first ?? job, mode: .fresh(fetched))
            if outcome == .done {
                appState.enrichmentLastError = nil
            }
            finishHead(servicedCount: (queue.first ?? job).noteRelativePaths.count)
            return
        }
    }

    private func finishHead(servicedCount: Int) {
        guard !queue.isEmpty else { return }
        var job = queue.removeFirst()
        // Coalesces that landed after the mutation pass read its paths: they
        // re-enqueue as a fresh job and are serviced via the ledger, no fetch.
        if job.noteRelativePaths.count > servicedCount {
            job.noteRelativePaths.removeFirst(servicedCount)
            job.attempts = 0
            queue.append(job)
        }
    }

    private func giveUp(job: Job, transport: Bool, message: String) {
        if transport {
            consecutiveTransportFailures += 1
            if consecutiveTransportFailures >= Self.cooldownThreshold {
                cooldownUntil = clock().addingTimeInterval(Self.failureCooldown)
            }
        }
        appState.enrichmentLastError = message
        Self.log.info("enrichment gave up on \(job.fingerprint, privacy: .public)")
        if !queue.isEmpty { queue.removeFirst() }
    }

    private nonisolated static func giveUpMessage(for type: CaptureType) -> String {
        type == .youtubeLink
            ? "Couldn't fetch the transcript for the last YouTube link — the note filed normally"
            : "Couldn't fetch the last article link — the note filed normally"
    }

    private nonisolated static func fetch(echo: LinkNoteEcho, fetcher: any LinkFetching) async throws -> FetchedLinkContent {
        switch echo.type {
        case .youtubeLink:
            guard let url = URL(string: echo.rawMedia),
                  let videoID = TitleDeriver.youTubeVideoID(url) else { throw LinkFetchError.unusableContent }
            return try await fetcher.fetchYouTube(videoID: videoID)
        default:
            guard let url = URL(string: echo.rawMedia) else { throw LinkFetchError.unusableContent }
            return try await fetcher.fetchArticle(url: url)
        }
    }

    private nonisolated static func asFetchError(_ error: Error) -> LinkFetchError {
        if let fetchError = error as? LinkFetchError { return fetchError }
        if case AIEngineError.timeout = error { return .timeout }
        return .network(error.localizedDescription)
    }

    // MARK: - Phase B (gated mutation)

    private enum MutateMode {
        case fresh(FetchedLinkContent)
        case dedup(EnrichedLinkEntry)
    }

    private enum MutateOutcome: Equatable {
        case done
        /// Paused / relocating / volume absent — try again shortly.
        case deferred
        /// Toggle off, notes gone, or unrecoverable mutation failure.
        case dropped
        /// Ledger entry's artifact no longer exists — re-fetch.
        case artifactMissing
    }

    private func mutateWithDeferrals(job: Job, mode: MutateMode) async -> MutateOutcome {
        let deferralStart = clock()
        while true {
            let outcome = await mutate(job: queue.first ?? job, mode: mode)
            guard outcome == .deferred else { return outcome }
            guard clock().timeIntervalSince(deferralStart) < Self.deferBudget else { return .dropped }
            await sleeper(Self.deferRetryInterval)
        }
    }

    private func mutate(job: Job, mode: MutateMode) async -> MutateOutcome {
        await appState.captureGate.withLock {
            let settings = appState.settings.settings
            guard settings.linkEnrichmentEnabled else { return .dropped }
            guard !settings.paused, !appState.isRelocating, let folder = settings.outputFolder else { return .deferred }
            guard destinationGuard.check(folder) == .available else { return .deferred }

            let existingNotes = job.noteRelativePaths.filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            // Never write an artifact whose capture pointer would be stillborn.
            guard !existingNotes.isEmpty else { return .dropped }

            switch mode {
            case .dedup(let entry):
                let artifactURL = folder.appendingPathComponent(entry.artifactRelativePath)
                guard FileManager.default.fileExists(atPath: artifactURL.path) else { return .artifactMissing }
                let title = entry.title.isEmpty ? nil : entry.title
                for notePath in existingNotes {
                    _ = await applyToNote(
                        relativePath: notePath, in: folder, title: title,
                        artifactFilename: artifactURL.lastPathComponent)
                }
                return .done

            case .fresh(let fetched):
                let title = fetched.title.flatMap(TitleDeriver.enrichedLinkTitle)

                // Rename + append every captured note first; the FIRST note's
                // final name is what the artifact's capture pointer records.
                var finalFirstNoteFilename: String?
                var appendTargets: [(relativePath: String, filename: String)] = []
                for notePath in existingNotes {
                    let result = await applyRename(relativePath: notePath, in: folder, title: title)
                    if finalFirstNoteFilename == nil { finalFirstNoteFilename = result.filename }
                    appendTargets.append((result.relativePath, result.filename))
                }
                guard let captureFilename = finalFirstNoteFilename else { return .dropped }

                // Artifact into Links/Media/, collision-walked.
                let mediaDir = folder.appendingPathComponent("Links/Media", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                } catch {
                    Self.log.warning("couldn't create Links/Media: \(error.localizedDescription, privacy: .public)")
                    return .dropped
                }
                let artifactBase = artifactFilenameBase(title: title, job: job)
                let (artifactURL, _) = FileWriter.uniqueDestination(in: mediaDir, baseName: artifactBase, fileExtension: "md")
                let artifact = EnrichmentArtifact.compose(
                    source: job.echo.rawMedia,
                    fetchedAt: clock(),
                    captureNoteFilename: captureFilename,
                    kind: job.echo.type == .youtubeLink ? .youtubeTranscript : .articleExtract,
                    body: fetched.bodyMarkdown
                )
                do {
                    try AtomicFile.write(Data(artifact.utf8), to: artifactURL)
                } catch {
                    Self.log.warning("couldn't write artifact: \(error.localizedDescription, privacy: .public)")
                    return .dropped
                }

                for target in appendTargets {
                    await appendMediaLink(
                        noteRelativePath: target.relativePath, in: folder,
                        label: title ?? artifactURL.deletingPathExtension().lastPathComponent,
                        artifactFilename: artifactURL.lastPathComponent)
                }

                // Ledger last: a crash anywhere above leaves valid notes and, at
                // worst, an unrecorded artifact a later re-capture re-fetches.
                ledger.record(
                    fingerprint: job.fingerprint,
                    artifactRelativePath: CaptureContract.relativePath(of: artifactURL, in: folder),
                    title: title ?? ""
                )
                return .done
            }
        }
    }

    /// `YYYY-MM-DD <Title>` like every note; date from the capture that
    /// triggered the fetch.
    private func artifactFilenameBase(title: String?, job: Job) -> String {
        let fallback = job.echo.type == .youtubeLink ? "YouTube Transcript" : "Article"
        return CaptureContract.filenameBase(title: title ?? fallback, capturedAt: job.echo.capturedAt)
    }

    /// Dedup path: rename (when a stored title exists) + append, one note.
    private func applyToNote(relativePath: String, in folder: URL, title: String?, artifactFilename: String) async -> Bool {
        let renamed = await applyRename(relativePath: relativePath, in: folder, title: title)
        await appendMediaLink(
            noteRelativePath: renamed.relativePath, in: folder,
            label: title ?? (artifactFilename as NSString).deletingPathExtension,
            artifactFilename: artifactFilename)
        return true
    }

    /// One-time pair-aware collision-safe rename to `<same date> <real title>`.
    /// Returns the note's (possibly unchanged) relative path + filename.
    private func applyRename(relativePath: String, in folder: URL, title: String?) async -> (relativePath: String, filename: String) {
        let noteURL = folder.appendingPathComponent(relativePath)
        let unchanged = (relativePath, noteURL.lastPathComponent)
        guard let title else { return unchanged }

        let currentBase = noteURL.deletingPathExtension().lastPathComponent
        let datePrefix = String(currentBase.prefix(10))
        // Only contract-shaped names rename; anything else keeps its name.
        guard datePrefix.count == 10, datePrefix.filter({ $0 == "-" }).count == 2 else { return unchanged }
        let newBase = datePrefix + " " + title
        guard newBase != currentBase else { return unchanged }

        let subfolder = noteURL.deletingLastPathComponent()
        let (newURL, attachmentFolderName) = FileWriter.uniqueDestination(in: subfolder, baseName: newBase, fileExtension: "md")
        do {
            try FileManager.default.moveItem(at: noteURL, to: newURL)
        } catch {
            Self.log.warning("rename failed for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return unchanged
        }

        // Attachment sibling folder moves in lockstep; compensate on failure.
        let oldAttachmentDir = subfolder.appendingPathComponent(currentBase, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: oldAttachmentDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let newAttachmentDir = subfolder.appendingPathComponent(attachmentFolderName, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: oldAttachmentDir, to: newAttachmentDir)
                await rewriteFooter(at: newURL, from: currentBase, to: attachmentFolderName)
            } catch {
                try? FileManager.default.moveItem(at: newURL, to: noteURL)
                Self.log.warning("attachment-pair rename failed for \(relativePath, privacy: .public); compensated")
                return unchanged
            }
        }

        let newRelativePath = CaptureContract.relativePath(of: newURL, in: folder)
        // Keep ghost-draining and orphan-audio placement pointing at the real file.
        triageLedger.remap([relativePath: newRelativePath])
        return (newRelativePath, newURL.lastPathComponent)
    }

    /// Best-effort footer rewrite after a pair rename (the migrator's rule: a
    /// failure leaves an honest stale link, never data loss).
    private func rewriteFooter(at noteURL: URL, from oldFolder: String, to newFolder: String) async {
        guard oldFolder != newFolder else { return }
        guard let data = await detachedRead(noteURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard let rewritten = CaptureContract.rewriteFooterFolder(inMarkdown: text, from: oldFolder, to: newFolder) else { return }
        try? AtomicFile.write(Data(rewritten.utf8), to: noteURL)
    }

    private func appendMediaLink(noteRelativePath: String, in folder: URL, label: String, artifactFilename: String) async {
        let noteURL = folder.appendingPathComponent(noteRelativePath)
        guard let data = await detachedRead(noteURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        // Notes live in Links/, artifacts in Links/Media/ — one hop down.
        guard let appended = EnrichmentArtifact.appendingMediaLink(
            toMarkdown: text, label: label, target: "Media/\(artifactFilename)") else { return }
        do {
            try AtomicFile.write(Data(appended.utf8), to: noteURL)
        } catch {
            Self.log.warning("media-link append failed for \(noteRelativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads must not block the main actor (dataless File-Provider files can
    /// stall until download) — the TriageProcessor discipline.
    private func detachedRead(_ url: URL) async -> Data? {
        try? await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }
}
