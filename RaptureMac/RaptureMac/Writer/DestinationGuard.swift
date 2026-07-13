import Foundation

/// Classifies the destination folder's availability so writers can tell an
/// unplugged external volume apart from a merely missing folder.
///
/// The distinction is load-bearing: `/Volumes` itself lives on the boot volume,
/// so `createDirectory(withIntermediateDirectories: true)` against a path on an
/// unplugged drive would silently create a **shadow folder** at
/// `/Volumes/<name>` on the boot volume and strand captures there — remounting
/// the real drive then hides that folder entirely. `volumeAbsent` means "queue,
/// never create"; `folderMissing` means "create as always".
/// `nonisolated`: the project defaults to MainActor isolation, but this guard is
/// pure and must be constructible from nonisolated contexts (default arguments,
/// detached work).
nonisolated struct DestinationGuard: Sendable {
    enum Check: Equatable, Sendable {
        /// The folder exists; write normally.
        case available
        /// The folder's `/Volumes/<name>` mount root is not a mounted volume.
        /// Nothing may be created anywhere under it.
        case volumeAbsent
        /// The folder is missing but its volume is present (boot volume paths,
        /// or a mounted external whose subfolder was deleted). Create it.
        case folderMissing
    }

    /// Probes are injectable so tests never need a real external drive.
    private let directoryExists: @Sendable (String) -> Bool
    private let isVolumeRoot: @Sendable (String) -> Bool

    init(
        directoryExists: @escaping @Sendable (String) -> Bool = Self.defaultDirectoryExists,
        isVolumeRoot: @escaping @Sendable (String) -> Bool = Self.defaultIsVolumeRoot
    ) {
        self.directoryExists = directoryExists
        self.isVolumeRoot = isVolumeRoot
    }

    func check(_ folder: URL) -> Check {
        Self.classify(
            path: folder.standardizedFileURL.path,
            directoryExists: directoryExists,
            isVolumeRoot: isVolumeRoot
        )
    }

    /// Pure decision. A path under `/Volumes/<name>` whose mount root is missing
    /// — or present but not a real volume root (a leftover shadow folder) — is
    /// `volumeAbsent`. Everything else missing is `folderMissing`.
    static func classify(
        path: String,
        directoryExists: (String) -> Bool,
        isVolumeRoot: (String) -> Bool
    ) -> Check {
        if directoryExists(path) { return .available }

        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else {
            return .folderMissing
        }
        let mountRoot = "/Volumes/" + components[2]
        guard directoryExists(mountRoot), isVolumeRoot(mountRoot) else {
            return .volumeAbsent
        }
        return .folderMissing
    }

    // MARK: - Default probes

    @Sendable static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    @Sendable static func defaultIsVolumeRoot(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume ?? false
    }
}
