import Foundation
import Observation
import OSLog
import SwiftUI

@Observable
@MainActor
final class SettingsStore {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SettingsStore")
    @ObservationIgnored private static let fileName = "settings.json"

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

    /// Two-way binding for any property of `Settings`. Reads from the live struct,
    /// writes through `update { ... }` so persistence and observation both fire.
    func binding<V>(for keyPath: WritableKeyPath<Settings, V>) -> Binding<V> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
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
