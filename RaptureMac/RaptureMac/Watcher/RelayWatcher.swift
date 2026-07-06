import Foundation
import OSLog

/// Second capture source alongside `ChatDBWatcher`: polls the iCloud-synced relay
/// folder the Rapture iOS app writes into and yields batches of files ready to be
/// filed into the output folder.
///
/// Same polling shape as `ChatDBWatcher` (detached utility task, cancellable, an
/// `AsyncStream` consumed on the main actor), but each scan is a full snapshot of
/// the folder rather than a watermark advance. That makes catch-up after sleep or
/// restart automatic, and it makes batches re-derivable: anything the consumer
/// defers (pause, relocation, failure backoff) simply re-appears in the next scan.
///
/// All decision logic lives in pure `nonisolated static` helpers so the pairing
/// rules are unit-testable without a filesystem or a clock.
@MainActor
final class RelayWatcher {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "RelayWatcher")

    /// iCloud sync latency (seconds to minutes) dominates end-to-end delivery, so a
    /// 1s poll buys nothing over the chat.db watcher's cadence. 5s keeps the scan
    /// cheap and delivery still feels immediate once a file lands.
    nonisolated static let pollInterval: TimeInterval = 5

    /// How long a fresh `.txt` with no sign of a paired `.m4a` waits before filing
    /// text-only. The iPhone writes audio before the note, but iCloud gives no
    /// cross-file ordering guarantee; two poll ticks cover the common jitter.
    nonisolated static let pairingGrace: TimeInterval = 10

    /// When the paired `.m4a` is visible as an undownloaded placeholder we know
    /// audio exists, so wait longer for the download. Past this cap the note files
    /// text-only and the orphan-audio path recovers the audio later.
    nonisolated static let audioPlaceholderWaitCap: TimeInterval = 120

    /// An `.m4a` with no matching `.txt` (visible or placeholder) for this long is
    /// genuinely orphaned: either its note filed text-only before the audio synced,
    /// or the audio outlived a failed send. It gets filed standalone.
    nonisolated static let orphanAudioGrace: TimeInterval = 600

    /// The synced relay folder inside the Rapture iOS iCloud container. The Mac app
    /// has no iCloud entitlement of its own; it is unsandboxed and reads the local
    /// synced path directly. DEBUG builds watch a separate folder so a dev build
    /// never races the installed app over real relay files (same isolation rationale
    /// as `AppSupportDirectory`).
    nonisolated static var defaultRelayFolder: URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~noisemeld~Rapture", isDirectory: true)
        let name = AppSupportDirectory.isDebugContainer ? "Relay (Debug)" : "Relay"
        return container.appendingPathComponent(name, isDirectory: true)
    }

    private let folder: URL
    private var pollTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
    }

    /// Starts the polling loop. `enabledProvider` is read every tick, so the
    /// Settings toggle needs no watcher restart: disabled ticks post `.off` and skip
    /// the scan. `onStatus` receives deduplicated status changes.
    func batches(
        enabledProvider: @escaping @Sendable () async -> Bool,
        onStatus: @escaping @Sendable (RelayStatus) async -> Void
    ) -> AsyncStream<RelayScanBatch> {
        // Newest-only buffering: each batch is a full re-derivable snapshot, so a
        // stale queued snapshot is worthless once a newer one exists.
        let (stream, continuation) = AsyncStream<RelayScanBatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let folder = self.folder
        pollTask = Task.detached(priority: .utility) {
            var firstSeen: [String: Date] = [:]
            var lastPosted: RelayStatus?
            var loggedNudgeFailures: Set<String> = []

            func post(_ status: RelayStatus) async {
                guard status != lastPosted else { return }
                lastPosted = status
                await onStatus(status)
            }

            while !Task.isCancelled {
                if await !enabledProvider() {
                    firstSeen = [:]
                    await post(.off)
                } else if let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                    let plan = Self.plan(entries: entries, firstSeen: firstSeen, now: Date())
                    firstSeen = plan.newFirstSeen
                    for name in plan.placeholdersToNudge {
                        Self.nudgeDownload(
                            of: folder.appendingPathComponent(name),
                            loggedFailures: &loggedNudgeFailures
                        )
                    }
                    if plan.placeholdersToNudge.isEmpty {
                        await post(.watching)
                    } else {
                        await post(.waitingForDownload(count: plan.placeholdersToNudge.count))
                    }
                    let batch = RelayScanBatch(
                        candidates: plan.readyTxt.map { ready in
                            RelayCandidate(
                                txtURL: folder.appendingPathComponent(ready.name),
                                audioURL: ready.audioName.map { folder.appendingPathComponent($0) },
                                relayFilename: ready.name,
                                baseName: String(ready.name.dropLast(4))
                            )
                        },
                        orphanAudio: plan.orphanAudio.map { folder.appendingPathComponent($0) }
                    )
                    if !batch.candidates.isEmpty || !batch.orphanAudio.isEmpty {
                        continuation.yield(batch)
                    }
                } else {
                    // Folder absent (or unreadable): it appears only after the first
                    // iPhone send, so this is the normal idle state, not an error.
                    firstSeen = [:]
                    await post(.waitingForFolder)
                }
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Pure scan planner

    struct ReadyTxt: Equatable, Sendable {
        let name: String
        /// The paired `.m4a` name when it is fully downloaded; nil files text-only.
        let audioName: String?
    }

    struct RelayScanPlan: Equatable, Sendable {
        var readyTxt: [ReadyTxt]
        var orphanAudio: [String]
        /// Logical filenames still undownloaded (their `.icloud` placeholder exists).
        var placeholdersToNudge: [String]
        var newFirstSeen: [String: Date]
    }

    /// Classifies one directory snapshot into work. Pure: all timing decisions flow
    /// from the injected `firstSeen` map and `now`.
    nonisolated static func plan(entries: [String], firstSeen: [String: Date], now: Date) -> RelayScanPlan {
        var visibleTxt: Set<String> = []
        var visibleAudio: Set<String> = []
        var placeholderTargets: Set<String> = []

        for entry in entries {
            if let target = placeholderTarget(entry) {
                placeholderTargets.insert(target)
            } else if entry.hasPrefix(".") {
                continue // .DS_Store and other hidden files: ignored, never deleted
            } else if entry.lowercased().hasSuffix(".txt") {
                visibleTxt.insert(entry)
            } else if entry.lowercased().hasSuffix(".m4a") {
                visibleAudio.insert(entry)
            }
            // Unknown extensions: ignored, never deleted.
        }

        // Track first-seen for everything still present; names that vanished are
        // pruned by rebuilding the map from the current snapshot.
        var newFirstSeen: [String: Date] = [:]
        for name in visibleTxt.union(visibleAudio).union(placeholderTargets) {
            newFirstSeen[name] = firstSeen[name] ?? now
        }

        var readyTxt: [ReadyTxt] = []
        for txt in visibleTxt.sorted() {
            let audioName = pairedAudioName(forTxt: txt)
            let age = now.timeIntervalSince(newFirstSeen[txt] ?? now)
            if visibleAudio.contains(audioName) {
                readyTxt.append(ReadyTxt(name: txt, audioName: audioName))
            } else if placeholderTargets.contains(audioName) {
                // Audio exists but has not downloaded; wait longer, then give up
                // and file text-only (the orphan path recovers the audio later).
                if age >= audioPlaceholderWaitCap {
                    readyTxt.append(ReadyTxt(name: txt, audioName: nil))
                }
            } else if age >= pairingGrace {
                readyTxt.append(ReadyTxt(name: txt, audioName: nil))
            }
        }

        var orphanAudio: [String] = []
        for m4a in visibleAudio.sorted() {
            let txtName = pairedTxtName(forAudio: m4a)
            guard !visibleTxt.contains(txtName), !placeholderTargets.contains(txtName) else { continue }
            let age = now.timeIntervalSince(newFirstSeen[m4a] ?? now)
            if age >= orphanAudioGrace {
                orphanAudio.append(m4a)
            }
        }

        return RelayScanPlan(
            readyTxt: readyTxt,
            orphanAudio: orphanAudio,
            placeholdersToNudge: placeholderTargets.sorted(),
            newFirstSeen: newFirstSeen
        )
    }

    /// `. <name>.icloud` placeholder → the logical filename it stands for, or nil
    /// for anything that is not an iCloud placeholder (e.g. `.DS_Store`).
    nonisolated static func placeholderTarget(_ filename: String) -> String? {
        guard filename.hasPrefix("."), filename.hasSuffix(".icloud") else { return nil }
        let target = String(filename.dropFirst().dropLast(".icloud".count))
        return target.isEmpty ? nil : target
    }

    nonisolated static func pairedAudioName(forTxt name: String) -> String {
        String(name.dropLast(4)) + ".m4a"
    }

    nonisolated static func pairedTxtName(forAudio name: String) -> String {
        String(name.dropLast(4)) + ".txt"
    }

    /// Parses the capture timestamp from a contract-shaped relay filename
    /// (`YYYY-MM-DDTHH-MM-SSZ <title>.ext`, first 20 characters). Informational
    /// only: a non-contract filename still files with a best-effort basename.
    nonisolated static func parseRelayTimestamp(_ filename: String) -> Date? {
        guard filename.count >= 20 else { return nil }
        var stamp = String(filename.prefix(20))
        guard stamp.hasSuffix("Z") else { return nil }
        // Time separators arrive as "-" (filesystem-safe); restore ":" for ISO8601.
        let timeStart = stamp.index(stamp.startIndex, offsetBy: 13)
        let timeMid = stamp.index(stamp.startIndex, offsetBy: 16)
        guard stamp[timeStart] == "-", stamp[timeMid] == "-" else { return nil }
        stamp.replaceSubrange(timeStart...timeStart, with: ":")
        stamp.replaceSubrange(timeMid...timeMid, with: ":")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }

    // MARK: - Placeholder downloads

    /// Asks the file provider to materialize an undownloaded item. Primary path is
    /// `startDownloadingUbiquitousItem`; if that throws (the app has no iCloud
    /// entitlement of its own, so it may for another app's container), fall back to
    /// a coordinated read intent, which also requests materialization. The fallback
    /// runs detached because a read intent blocks until the download completes and
    /// must not stall the poll loop. Both are file-system APIs; no networking.
    nonisolated static func nudgeDownload(of url: URL, loggedFailures: inout Set<String>) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            let name = url.lastPathComponent
            guard !loggedFailures.contains(name) else { return }
            loggedFailures.insert(name)
            log.warning("startDownloadingUbiquitousItem failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public); trying coordinated read")
            Task.detached(priority: .utility) {
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in }
                if let coordinationError {
                    log.warning("Coordinated read for \(name, privacy: .public) failed: \(coordinationError.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
