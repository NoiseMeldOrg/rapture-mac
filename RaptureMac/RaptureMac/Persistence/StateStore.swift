import Foundation
import OSLog

@MainActor
final class StateStore {
    private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "StateStore")
    private static let fileName = "state.json"

    private(set) var state: PersistedState

    init() {
        self.state = Self.load() ?? PersistedState()
    }

    func update(_ mutate: (inout PersistedState) -> Void) {
        mutate(&state)
        save()
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
