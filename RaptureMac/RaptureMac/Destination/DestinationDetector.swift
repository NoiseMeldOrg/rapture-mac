import Foundation

/// A place the user might want notes to go, found on this Mac. In memory
/// only, re-detected every time the picker is shown: a vault added a minute
/// ago appears, and a drive unplugged a second ago shows as unreachable.
struct DetectedDestination: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable {
        case obsidian
        case iCloudDrive
        case dropbox
        case googleDrive
        case oneDrive
    }

    let name: String
    let path: URL
    let source: Source
    /// False when the folder lives on an external drive that isn't connected.
    let reachable: Bool

    var id: String { path.path }

    var isVault: Bool { source == .obsidian }

    /// "Second Brain — Obsidian vault"
    var label: String {
        switch source {
        case .obsidian: return "\(name) — Obsidian vault"
        case .iCloudDrive, .dropbox, .googleDrive, .oneDrive: return name
        }
    }
}

/// Finds Obsidian vaults (from Obsidian's own config) and sync roots (iCloud
/// Drive, Dropbox, Google Drive, OneDrive). Reads a few local paths; no
/// network, no entitlement (the app is unsandboxed). Every input is injected,
/// so tests never depend on what is installed on the machine running them.
/// Detection decides *where* notes could go, never *how* they are written.
enum DestinationDetector {

    struct Environment: Sendable {
        var home: URL
        /// Obsidian's vault list: `{"vaults": {"<id>": {"path": "/abs"}}}`.
        var obsidianConfig: URL
        var destinationGuard: DestinationGuard
        var listDirectory: @Sendable (URL) -> [String]

        static var live: Environment {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Environment(
                home: home,
                obsidianConfig: home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json"),
                destinationGuard: DestinationGuard(),
                listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            )
        }
    }

    /// Vaults first (sorted by name), then sync roots.
    nonisolated static func detect(in env: Environment = .live) -> [DetectedDestination] {
        vaults(in: env) + syncRoots(in: env)
    }

    // MARK: - Obsidian

    /// Vault paths from Obsidian's config. Malformed, missing, or empty
    /// config means no vaults, never an error.
    nonisolated static func parseObsidianVaultPaths(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: Any] else { return [] }
        return vaults.values.compactMap { ($0 as? [String: Any])?["path"] as? String }
            .filter { $0.hasPrefix("/") }
    }

    nonisolated static func vaults(in env: Environment) -> [DetectedDestination] {
        guard let data = try? Data(contentsOf: env.obsidianConfig) else { return [] }
        var seen = Set<String>()
        var result: [DetectedDestination] = []
        for path in parseObsidianVaultPaths(data) {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            switch env.destinationGuard.check(url) {
            case .available:
                result.append(DetectedDestination(name: url.lastPathComponent, path: url, source: .obsidian, reachable: true))
            case .volumeAbsent:
                // Shown, never hidden: a vault on an unplugged drive is still
                // the user's vault, and hiding it would look like detection broke.
                result.append(DetectedDestination(name: url.lastPathComponent, path: url, source: .obsidian, reachable: false))
            case .folderMissing:
                // Deleted or moved on a present drive: Obsidian's list is stale.
                continue
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Sync roots

    nonisolated static func syncRoots(in env: Environment) -> [DetectedDestination] {
        var result: [DetectedDestination] = []
        let iCloud = env.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if env.destinationGuard.check(iCloud) == .available {
            result.append(DetectedDestination(name: "iCloud Drive", path: iCloud, source: .iCloudDrive, reachable: true))
        }
        let cloudStorage = env.home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        for entry in env.listDirectory(cloudStorage).sorted() {
            let url = cloudStorage.appendingPathComponent(entry, isDirectory: true)
            if entry == "Dropbox" || entry.hasPrefix("Dropbox-") {
                result.append(DetectedDestination(name: "Dropbox", path: url, source: .dropbox, reachable: true))
            } else if entry.hasPrefix("GoogleDrive-") {
                // Google Drive's own files live under "My Drive".
                let myDrive = url.appendingPathComponent("My Drive", isDirectory: true)
                if env.destinationGuard.check(myDrive) == .available {
                    result.append(DetectedDestination(name: "Google Drive", path: myDrive, source: .googleDrive, reachable: true))
                }
            } else if entry.hasPrefix("OneDrive-") {
                result.append(DetectedDestination(name: "OneDrive", path: url, source: .oneDrive, reachable: true))
            }
        }
        return result
    }
}
