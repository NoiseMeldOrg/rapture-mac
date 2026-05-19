import Foundation
import OSLog

@MainActor
final class SettingsStore {
    private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SettingsStore")
    private static let fileName = "settings.json"

    private(set) var settings: Settings

    init() {
        self.settings = Self.load() ?? Settings()
    }

    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        save()
    }

    func ensureDefaultOutputFolder() {
        guard settings.outputFolder == nil else { return }
        let defaultFolder = AppSupportDirectory.defaultOutputFolder
        do {
            try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Failed to create default output folder: \(error.localizedDescription, privacy: .public)")
        }
        update { $0.outputFolder = defaultFolder }
    }

    private static func fileURL() throws -> URL {
        try AppSupportDirectory.url().appendingPathComponent(fileName)
    }

    private static func load() -> Settings? {
        do {
            let url = try fileURL()
            guard let data = try AtomicFile.read(url) else { return nil }
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            log.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(settings)
            let url = try Self.fileURL()
            try AtomicFile.write(data, to: url)
        } catch {
            Self.log.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
