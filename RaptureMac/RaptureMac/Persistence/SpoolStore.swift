import Foundation
import OSLog

/// The internal capture spool: while the destination's volume is absent, iMessage
/// captures queue here (in the app-support container — boot volume, DEBUG-isolated,
/// always writable) instead of being written toward the unplugged drive.
///
/// The spool **directory is the state** — the same idiom as the relay folder. Each
/// item is a self-describing subdirectory `<seq>-<timestamp>/` holding
/// `capture.txt`, `meta.json`, and optionally `attachments/`. Items commit
/// atomically: they are assembled in a dot-prefixed staging directory and renamed
/// into place, and the scanner ignores dot-prefixed names plus any directory
/// without a `meta.json` — a crash mid-spool can never produce a half-item that
/// flushes.
///
/// Ordering: the seq component comes from `PersistedState.spoolNextSeq`, which is
/// monotonic for the app's lifetime (never resets when the spool drains), so names
/// are unique forever and lexicographic order of the zero-padded prefix is capture
/// order.
@MainActor
final class SpoolStore {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SpoolStore")

    nonisolated static let captureTextFilename = "capture.txt"
    nonisolated static let metadataFilename = "meta.json"
    nonisolated static let attachmentsDirectoryName = "attachments"
    nonisolated static let spoolDirectoryName = "Spool"
    nonisolated static let attachmentRetryDelay: TimeInterval = 2

    enum SpoolError: LocalizedError {
        case noSpoolDirectory(String)

        var errorDescription: String? {
            switch self {
            case .noSpoolDirectory(let detail):
                return "Couldn't prepare the capture queue: \(detail)"
            }
        }
    }

    private let stateStore: StateStore
    /// Test override; nil resolves the app-support container lazily (it can throw).
    private let directoryOverride: URL?
    private let clock: @Sendable () -> Date

    init(
        directory: URL? = nil,
        stateStore: StateStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryOverride = directory
        self.stateStore = stateStore
        self.clock = clock
    }

    private func spoolRoot() throws -> URL {
        if let directoryOverride { return directoryOverride }
        return try AppSupportDirectory.url()
            .appendingPathComponent(Self.spoolDirectoryName, isDirectory: true)
    }

    // MARK: - Enqueue

    /// Queues one capture. Attachments are copied in now — the sources (e.g.
    /// `~/Library/Messages/Attachments`) aren't guaranteed to survive a long
    /// offline stretch. Copy failures are recorded in the metadata rather than
    /// failing the spool: the text is the capture; the flush re-reports them.
    @discardableResult
    func add(
        text: String,
        capturedAt: Date,
        source: CaptureSource,
        attachments: [AttachmentRef] = []
    ) async throws -> SpoolItem {
        let root = try spoolRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let seq = nextSeq(existingIn: root)
        let name = Self.itemName(seq: seq, capturedAt: capturedAt)
        let staging = root.appendingPathComponent(".staging-\(name)", isDirectory: true)
        let final = root.appendingPathComponent(name, isDirectory: true)

        // A previous crashed attempt may have left staging debris under this name;
        // seqs are never reused, so anything there is garbage.
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var failedAttachments: [String] = []
        if !attachments.isEmpty {
            let attachmentsDir = staging.appendingPathComponent(Self.attachmentsDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            for attachment in attachments {
                let sourceURL = URL(fileURLWithPath: attachment.sourcePath)
                let rawName = attachment.transferName ?? sourceURL.lastPathComponent
                let filename = FileWriter.sanitizeAttachmentFilename(rawName)
                let destination = attachmentsDir.appendingPathComponent(filename)
                if await Self.copyWithRetry(from: sourceURL, to: destination) == false {
                    failedAttachments.append(attachment.sourcePath)
                }
            }
        }

        let metadata = SpoolMetadata(
            capturedAt: capturedAt,
            source: source,
            seq: seq,
            spooledAt: clock(),
            failedAttachments: failedAttachments
        )
        try Data(text.utf8).write(to: staging.appendingPathComponent(Self.captureTextFilename))
        try Self.encoder.encode(metadata).write(to: staging.appendingPathComponent(Self.metadataFilename))

        // Commit: the rename makes the whole item visible at once.
        try FileManager.default.moveItem(at: staging, to: final)
        Self.log.info("spooled \(name, privacy: .public)")
        return SpoolItem(directory: final, metadata: metadata)
    }

    // MARK: - Scan

    /// Committed items in flush (capture) order. Uncommitted debris — dot-prefixed
    /// staging dirs or directories without a readable `meta.json` — is invisible.
    func items() -> [SpoolItem] {
        guard let root = try? spoolRoot(),
              let children = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: []
              )
        else { return [] }

        var result: [SpoolItem] = []
        for child in children {
            guard !child.lastPathComponent.hasPrefix(".") else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metaURL = child.appendingPathComponent(Self.metadataFilename)
            guard let data = try? Data(contentsOf: metaURL),
                  let metadata = try? Self.decoder.decode(SpoolMetadata.self, from: data)
            else { continue }
            result.append(SpoolItem(directory: child, metadata: metadata))
        }
        return result.sorted { $0.metadata.seq < $1.metadata.seq }
    }

    var count: Int { items().count }

    var isEmpty: Bool { items().isEmpty }

    // MARK: - Dequeue

    /// Removes a flushed (or ledger-resumed) item. Deletion honors the house
    /// directory-removal invariant: known files are removed individually, then the
    /// emptied directories fall to the guarded primitive. `meta.json` goes first —
    /// it is the commit marker, so a crash mid-removal leaves an uncommitted
    /// directory the scanner already ignores.
    func remove(_ item: SpoolItem) {
        try? FileManager.default.removeItem(at: item.metadataURL)
        try? FileManager.default.removeItem(at: item.captureTextURL)
        let attachmentsDir = item.attachmentsDirectory
        if let files = try? FileManager.default.contentsOfDirectory(
            at: attachmentsDir, includingPropertiesForKeys: nil, options: []
        ) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        FileSafety.removeIfEmpty(attachmentsDir)
        FileSafety.removeIfEmpty(item.directory)
    }

    // MARK: - Helpers

    /// The persisted counter is authoritative; existing item seqs are a floor so a
    /// lost/reset `state.json` can never mint a name that collides with a queued
    /// item.
    private func nextSeq(existingIn root: URL) -> Int {
        let persisted = stateStore.state.spoolNextSeq
        let maxExisting = items().map(\.metadata.seq).max() ?? 0
        let seq = max(persisted, maxExisting + 1)
        stateStore.update { $0.spoolNextSeq = seq + 1 }
        return seq
    }

    nonisolated static func itemName(seq: Int, capturedAt: Date) -> String {
        String(format: "%08d", seq) + "-" + FileWriter.baseName(for: capturedAt)
    }

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Same one-retry convention as `FileWriter.copyAttachment`.
    private nonisolated static func copyWithRetry(from source: URL, to destination: URL) async -> Bool {
        if copyIfSourceExists(from: source, to: destination) { return true }
        try? await Task.sleep(for: .seconds(attachmentRetryDelay))
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
