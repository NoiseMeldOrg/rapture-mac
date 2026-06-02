import Foundation
import Observation
import OSLog
import SwiftUI

/// Reads/writes the autonomous-watcher's KEY=VALUE config file at
/// `~/.config/rapture-mac/watch.env`. The bundled `install-claude-watch.sh`
/// reads this file on every run and injects each key into the launchd
/// plist's `EnvironmentVariables` via PlistBuddy — so the panel writes here,
/// then re-runs the installer to push the values into launchd.
///
/// On read, `#` comment lines and blank lines are skipped. On write, the
/// file is regenerated from the in-memory dictionary in alphabetical key
/// order, one `KEY=VALUE` per line. Comments are not round-tripped (the
/// `examples/watch.env.example` template lives in the bundle separately).
@Observable
@MainActor
final class WatcherConfigStore {
    @ObservationIgnored private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "WatcherConfigStore")

    @ObservationIgnored private let fileURL: URL
    private(set) var values: [String: String] = [:]

    init(fileURL: URL = WatcherConfigStore.defaultFileURL) {
        self.fileURL = fileURL
        self.values = Self.load(from: fileURL) ?? [:]
    }

    /// Sets `key` to `value` and persists. Empty value writes through (caller's
    /// choice); use `remove(_:)` to drop a key entirely.
    func set(_ key: String, _ value: String) {
        values[key] = value
        save()
    }

    func remove(_ key: String) {
        values.removeValue(forKey: key)
        save()
    }

    /// Two-way SwiftUI binding for a key. Returns the empty string when the key
    /// is absent. Setting "" writes "" through; use `remove(_:)` for true delete.
    func binding(forKey key: String) -> Binding<String> {
        Binding(
            get: { self.values[key] ?? "" },
            set: { self.set(key, $0) }
        )
    }

    nonisolated static var defaultFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/rapture-mac/watch.env")
    }

    // MARK: - Persistence

    static func load(from url: URL) -> [String: String]? {
        do {
            guard let data = try AtomicFile.read(url) else { return [:] }
            guard let text = String(data: data, encoding: .utf8) else { return [:] }
            return parse(text)
        } catch {
            log.error("Failed to read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func save() {
        do {
            let text = Self.serialize(values)
            try AtomicFile.write(Data(text.utf8), to: fileURL)
        } catch {
            Self.log.error("Failed to write \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parse / serialize (pure, testable)

    nonisolated static func parse(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            let value = String(line[line.index(after: eq)...])
            dict[key] = value
        }
        return dict
    }

    nonisolated static func serialize(_ dict: [String: String]) -> String {
        let sortedKeys = dict.keys.sorted()
        var lines: [String] = []
        lines.reserveCapacity(sortedKeys.count)
        for key in sortedKeys {
            lines.append("\(key)=\(dict[key] ?? "")")
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
