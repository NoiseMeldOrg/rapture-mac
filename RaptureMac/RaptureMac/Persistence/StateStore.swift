import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class StateStore {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "StateStore")
    @ObservationIgnored private static let fileName = "state.json"

    private(set) var state: PersistedState

    init() {
        self.state = Self.load() ?? PersistedState()
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

    private static func fileURL() throws -> URL {
        try AppSupportDirectory.url().appendingPathComponent(fileName)
    }

    private static func load() -> PersistedState? {
        do {
            let url = try fileURL()
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
            let url = try Self.fileURL()
            try AtomicFile.write(data, to: url)
        } catch {
            Self.log.error("Failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
