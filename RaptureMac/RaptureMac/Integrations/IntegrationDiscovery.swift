import Foundation
import OSLog

private let log = Logger(subsystem: "noisemeld.RaptureMac", category: "IntegrationDiscovery")

// MARK: - Public model

struct ConsumerCard: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let folderURL: URL
    let docs: [DocLink]
    let installs: [InstallProfile]
}

struct DocLink: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let fileURL: URL
}

struct InstallProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let install: URL?
    let uninstall: URL?
    let start: URL?
    let stop: URL?
    let restart: URL?
    let logs: [URL]
    let statusKey: StatusKey?
    let configFile: URL?
    let config: [ConfigField]
    let requires: Requires
}

enum StatusKey: Equatable, Sendable {
    case hook
    case watcher
    case unknown(String)

    init(_ raw: String) {
        switch raw {
        case "hook":    self = .hook
        case "watcher": self = .watcher
        default:        self = .unknown(raw)
        }
    }
}

struct ConfigField: Identifiable, Equatable, Sendable {
    let key: String
    let label: String
    let kind: Kind
    let `default`: String?

    var id: String { key }

    enum Kind: Equatable, Sendable {
        case folder
        case select([String])
        case string
    }
}

struct Requires: Equatable, Sendable {
    var cli: [String]
    var brew: [String]
    var tcc: [String]

    static let empty = Requires(cli: [], brew: [], tcc: [])
    var isEmpty: Bool { cli.isEmpty && brew.isEmpty && tcc.isEmpty }
}

// MARK: - Discovery

enum IntegrationDiscovery {
    /// Walks `examplesRoot`, building one `ConsumerCard` per subfolder.
    /// Pure function modulo file I/O. Sorted alphabetically by folder name for stable order.
    /// Individual folder errors are logged and skipped; only an unreadable `examplesRoot` throws.
    nonisolated static func discover(examplesRoot: URL, scriptsRoot: URL) throws -> [ConsumerCard] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: examplesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error("Cannot read examplesRoot \(examplesRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let folders = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var cards: [ConsumerCard] = []
        cards.reserveCapacity(folders.count)
        for folder in folders {
            if let card = makeCard(folder: folder, scriptsRoot: scriptsRoot) {
                cards.append(card)
            }
        }
        return cards
    }

    // MARK: - Per-folder build

    private nonisolated static func makeCard(folder: URL, scriptsRoot: URL) -> ConsumerCard? {
        let folderName = folder.lastPathComponent
        let manifest = loadManifest(folder: folder)

        let readmeURL = folder.appendingPathComponent("README.md")
        let hasReadme = FileManager.default.fileExists(atPath: readmeURL.path)

        let displayName = manifest?.displayName ?? prettify(folderName)
        let description = manifest?.description
            ?? (hasReadme ? deriveDescription(from: readmeURL) : "")

        let docs: [DocLink]
        if let rawDocs = manifest?.docs {
            docs = rawDocs.compactMap { raw in
                guard let label = raw.label, let file = raw.file else { return nil }
                let url = resolvePath(file, folder: folder, scriptsRoot: scriptsRoot)
                return DocLink(id: file, label: label, fileURL: url)
            }
        } else if hasReadme {
            docs = [DocLink(id: "README.md", label: "README", fileURL: readmeURL)]
        } else {
            docs = []
        }

        let installs = (manifest?.installs ?? []).compactMap { raw in
            makeInstall(raw: raw, folder: folder, scriptsRoot: scriptsRoot)
        }

        return ConsumerCard(
            id: folderName,
            displayName: displayName,
            description: description,
            folderURL: folder,
            docs: docs,
            installs: installs
        )
    }

    private nonisolated static func makeInstall(raw: RawInstall, folder: URL, scriptsRoot: URL) -> InstallProfile? {
        guard let id = raw.id, let name = raw.name else {
            log.warning("Install entry missing id or name in \(folder.lastPathComponent, privacy: .public); skipping.")
            return nil
        }

        func resolveOptional(_ path: String?) -> URL? {
            path.map { resolvePath($0, folder: folder, scriptsRoot: scriptsRoot) }
        }

        let configFile = raw.configFile.map { expandTilde($0) }

        let configFields: [ConfigField] = (raw.config ?? []).compactMap { rawField in
            guard let key = rawField.key, let label = rawField.label, let typeStr = rawField.type else {
                return nil
            }
            let kind: ConfigField.Kind
            switch typeStr {
            case "folder": kind = .folder
            case "string": kind = .string
            case "select":
                kind = .select(rawField.options ?? [])
            default:
                log.warning("Unknown config type '\(typeStr, privacy: .public)' for key \(key, privacy: .public) in \(folder.lastPathComponent, privacy: .public); defaulting to string.")
                kind = .string
            }
            return ConfigField(key: key, label: label, kind: kind, default: rawField.default)
        }

        let logURLs: [URL] = (raw.logs ?? []).map { URL(fileURLWithPath: expandTildePath($0)) }

        let requires = Requires(
            cli: raw.requires?.cli ?? [],
            brew: raw.requires?.brew ?? [],
            tcc: raw.requires?.tcc ?? []
        )

        return InstallProfile(
            id: id,
            name: name,
            description: raw.description ?? "",
            install: resolveOptional(raw.install),
            uninstall: resolveOptional(raw.uninstall),
            start: resolveOptional(raw.start),
            stop: resolveOptional(raw.stop),
            restart: resolveOptional(raw.restart),
            logs: logURLs,
            statusKey: raw.statusKey.map { StatusKey($0) },
            configFile: configFile,
            config: configFields,
            requires: requires
        )
    }

    // MARK: - Manifest loading

    private nonisolated static func loadManifest(folder: URL) -> RawManifest? {
        let url = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            log.warning("Malformed manifest.json in \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to filesystem defaults.")
            return nil
        }
    }

    // MARK: - Path resolution

    /// Resolves a manifest path string:
    /// - absolute (`/...`)            → used as-is
    /// - `~/...`                      → expanded to home
    /// - `Scripts/<name>`             → `scriptsRoot/<name>`
    /// - other relative               → `folder/<path>`
    nonisolated static func resolvePath(_ path: String, folder: URL, scriptsRoot: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("~/") || path == "~" {
            return URL(fileURLWithPath: expandTildePath(path))
        }
        if path.hasPrefix("Scripts/") {
            let suffix = String(path.dropFirst("Scripts/".count))
            return scriptsRoot.appendingPathComponent(suffix)
        }
        return folder.appendingPathComponent(path)
    }

    nonisolated static func expandTilde(_ path: String) -> URL {
        URL(fileURLWithPath: expandTildePath(path))
    }

    nonisolated static func expandTildePath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Defaults

    /// `claude-code` → `Claude Code`. `generic-cli` → `Generic Cli`. Manifest overrides when this isn't right.
    nonisolated static func prettify(_ folderName: String) -> String {
        folderName
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Parses a README, skips past the first `# Heading`, returns the first non-blank paragraph after it.
    /// Falls back to the first non-blank paragraph if no H1 is found.
    nonisolated static func deriveDescription(from readmeURL: URL) -> String {
        guard let content = try? String(contentsOf: readmeURL, encoding: .utf8) else { return "" }
        return deriveDescription(fromMarkdown: content)
    }

    nonisolated static func deriveDescription(fromMarkdown content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Find the first H1; if there isn't one, start from the top.
        var i = 0
        var foundH1 = false
        for (idx, line) in lines.enumerated() where line.hasPrefix("# ") {
            i = idx + 1
            foundH1 = true
            break
        }
        if !foundH1 { i = 0 }
        // Skip blanks
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
        }
        // Collect lines until next blank or next heading
        var paragraph: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix("#") { break }
            paragraph.append(trimmed)
            i += 1
        }
        return paragraph.joined(separator: " ")
    }
}

// MARK: - Raw Codable types (private to the parser)

private struct RawManifest: Decodable {
    let displayName: String?
    let description: String?
    let docs: [RawDoc]?
    let installs: [RawInstall]?
}

private struct RawDoc: Decodable {
    let label: String?
    let file: String?
}

private struct RawInstall: Decodable {
    let id: String?
    let name: String?
    let description: String?
    let install: String?
    let uninstall: String?
    let start: String?
    let stop: String?
    let restart: String?
    let logs: [String]?
    let statusKey: String?
    let configFile: String?
    let config: [RawConfig]?
    let requires: RawRequires?
}

private struct RawConfig: Decodable {
    let key: String?
    let label: String?
    let type: String?
    let options: [String]?
    let `default`: String?
}

private struct RawRequires: Decodable {
    let cli: [String]?
    let brew: [String]?
    let tcc: [String]?
}
