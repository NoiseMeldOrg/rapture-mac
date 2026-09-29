import Foundation
import Observation
import OSLog

/// One line of the user-facing history: what the app did, when, and where the
/// result lives. Titles and paths only, never the note text.
struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case filed
        case meetingFiled
        case meetingUpdated
        case queued
        case failed
        case gaveUp
        case attachmentMissing
        case attachmentRecovered
        case reminderCreated
        case eventCreated
        case enriched
        case warning
        case info
    }

    /// Where a capture came from, in the words the user knows.
    enum Source: String, Codable, Sendable {
        case iMessage
        case iPhoneApp
        case folder
        case queue
        case app

        var displayName: String {
            switch self {
            case .iMessage: return "iMessage"
            case .iPhoneApp: return "iPhone app"
            case .folder: return "Notes folder"
            case .queue: return "Offline queue"
            case .app: return "Rapture"
            }
        }
    }

    /// Lets the Activity window delete a Reminders/Calendar item the app made.
    struct Undo: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case reminder, event }
        var kind: Kind
        var identifier: String
    }

    var id: UUID
    var at: Date
    var kind: Kind
    var source: Source
    /// One short line: "Budget planning", "Couldn't write: disk full".
    var summary: String
    /// Absolute path of the note (or rescued file) this event is about.
    var path: String?
    /// Set on reminder/event rows: how to undo them.
    var undo: Undo? = nil
    /// Set on the row recording an undo: the id of the row it undid. The log
    /// stays append-only; a row counts as undone when a later row points at it.
    var undoOf: UUID? = nil
}

/// The app's local history, the answer to "what happened to my capture?".
///
/// Append-only JSON Lines at `<app support>/activity.jsonl`, rotated to the
/// newest `keepLines` once it passes `maxBytes`. Never leaves the Mac: no
/// networking, no note bodies. The newest `memoryCap` events are held in
/// memory for the Activity window and the menu's "Show Last Note".
@Observable
@MainActor
final class ActivityLog {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "ActivityLog")
    nonisolated static let fileName = "activity.jsonl"
    nonisolated static let memoryCap = 300
    nonisolated static let maxBytes = 1_000_000
    nonisolated static let keepLines = 2_000

    /// Newest first.
    private(set) var recent: [ActivityEvent] = []

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let clock: @Sendable () -> Date

    init(directory: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
        if let url = try? fileURL(), let data = try? Data(contentsOf: url) {
            recent = Array(Self.decodeLines(data).suffix(Self.memoryCap).reversed())
        }
    }

    /// The most recent event that points at a note that still exists.
    var lastNote: ActivityEvent? {
        recent.first { event in
            guard [.filed, .meetingFiled, .meetingUpdated, .enriched].contains(event.kind), let path = event.path else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// Ids of rows that a later row undid.
    var undoneIDs: Set<UUID> { Set(recent.compactMap(\.undoOf)) }

    func record(
        _ kind: ActivityEvent.Kind, source: ActivityEvent.Source, _ summary: String,
        path: URL? = nil, undo: ActivityEvent.Undo? = nil, undoOf: UUID? = nil
    ) {
        let event = ActivityEvent(
            id: UUID(), at: clock(), kind: kind, source: source,
            summary: summary, path: path?.path(percentEncoded: false),
            undo: undo, undoOf: undoOf
        )
        recent.insert(event, at: 0)
        if recent.count > Self.memoryCap {
            recent.removeLast(recent.count - Self.memoryCap)
        }
        append(event)
    }

    func clear() {
        recent.removeAll()
        if let url = try? fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - File

    private func fileURL() throws -> URL {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(Self.fileName)
        }
        return try AppSupportDirectory.url().appendingPathComponent(Self.fileName)
    }

    private func append(_ event: ActivityEvent) {
        do {
            let url = try fileURL()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(event)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            if end + UInt64(line.count) > UInt64(Self.maxBytes) {
                try? handle.close()
                rotate(url)
            }
        } catch {
            Self.log.error("Couldn't write activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotate(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let kept = lines.suffix(Self.keepLines)
        var out = Data()
        for line in kept {
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        try? out.write(to: url, options: .atomic)
    }

    /// Tolerant decode: a torn or foreign line is skipped, never fatal.
    nonisolated static func decodeLines(_ data: Data) -> [ActivityEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(ActivityEvent.self, from: Data($0))
        }
    }
}
