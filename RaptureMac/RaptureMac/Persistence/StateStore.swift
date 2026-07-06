import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class StateStore {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "StateStore")
    @ObservationIgnored private static let fileName = "state.json"

    private(set) var state: PersistedState

    /// When set, state.json lives in this directory instead of the app-support
    /// container. Tests inject a temp directory so they can never read a dev
    /// machine's live ledger (milestone 4 dogfood finding: real relay filings
    /// in the debug container broke ledger-emptiness assertions).
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
        self.state = Self.load(from: directory) ?? PersistedState()
    }

    func update(_ mutate: (inout PersistedState) -> Void) {
        mutate(&state)
        save()
    }

    /// Day-rollover-aware success counter. Updates `todayCount` / `todayDate` / `lastCaptureAt`
    /// atomically and persists. UI reads via `state.displayedTodayCount(at:)`.
    func recordSuccess(at time: Date = Date(), calendar: Calendar = .current) {
        update {
            let (date, count) = PersistedState.incrementing(
                currentDate: $0.todayDate,
                currentCount: $0.todayCount,
                at: time,
                calendar: calendar
            )
            $0.todayDate = date
            $0.todayCount = count
            $0.lastCaptureAt = time
        }
    }

    private static func fileURL(in directory: URL?) throws -> URL {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName)
        }
        return try AppSupportDirectory.url().appendingPathComponent(fileName)
    }

    private static func load(from directory: URL?) -> PersistedState? {
        do {
            let url = try fileURL(in: directory)
            guard let data = try AtomicFile.read(url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            log.error("Failed to load state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            let url = try Self.fileURL(in: directory)
            try AtomicFile.write(data, to: url)
        } catch {
            Self.log.error("Failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
