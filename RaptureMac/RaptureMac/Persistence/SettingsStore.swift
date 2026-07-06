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

    /// When set, settings.json lives in this directory instead of the
    /// app-support container. Tests inject a temp directory so they can never
    /// read or write a dev machine's live settings (see StateStore.directory).
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
        self.settings = Self.load(from: directory) ?? Settings()
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
        OutputFolderSidecar.write(defaultFolder)
        // Opt-in only, and a no-op unless the freshly created folder is empty + CLAUDE.md-less.
        if settings.seedScaffold {
            OutputFolderScaffold.seedIfEligible(folder: defaultFolder)
        }
    }

    /// Two-way binding for any property of `Settings`. Reads from the live struct,
    /// writes through `update { ... }` so persistence and observation both fire.
    func binding<V>(for keyPath: WritableKeyPath<Settings, V>) -> Binding<V> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private static func fileURL(in directory: URL?) throws -> URL {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName)
        }
        return try AppSupportDirectory.url().appendingPathComponent(fileName)
    }

    private static func load(from directory: URL?) -> Settings? {
        do {
            let url = try fileURL(in: directory)
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
            let url = try Self.fileURL(in: directory)
            try AtomicFile.write(data, to: url)
        } catch {
            Self.log.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
