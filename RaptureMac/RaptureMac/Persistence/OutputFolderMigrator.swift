import Foundation
import OSLog

/// Moves the *contents* of one output folder into another when the user changes the
/// Output Folder in Settings — so the picked folder itself becomes the notes folder.
///
/// This relocates the user's only copy of their notes, so every path here is
/// data-safety first:
/// - **Same volume:** atomic per-item `moveItem`.
/// - **Cross volume:** copy → verify → only then delete the source. The source is
///   never removed before its destination is verified.
/// - **Collisions merge, never clobber.** `.md` config/routing files keep the existing
///   destination; everything else is disambiguated with a `<base>-<n>` suffix.
/// - **Any failure leaves the source intact** and the caller does not switch folders.
///
/// Pure and `FileManager`-injectable so it is fully unit-testable against temp dirs.
/// `nonisolated`: runs inside `Task.detached` from `AppState.setOutputFolder`, so
/// it must be callable off the main actor (the project defaults to MainActor).
nonisolated struct OutputFolderMigrator {

    /// What a relocation changed beyond moving files. `renamedNotes` maps
    /// destination-relative paths of collision-renamed notes (old → new), so the
    /// caller can remap `TriagedEntry.mdRelativePath` ledger entries.
    struct MigrationReport: Sendable, Equatable {
        var renamedNotes: [String: String] = [:]
    }

    /// Move-vs-copy selection. `.auto` decides by comparing volumes; the explicit cases
    /// let tests exercise the cross-volume path on a single volume.
    enum Strategy {
        case auto
        case move
        case copyVerifyDelete
    }

    enum MigrationError: LocalizedError {
        case nestedPaths(old: String, new: String)
        case destinationNotWritable(String)
        case insufficientSpace(needed: Int64, available: Int64)
        case verificationFailed(item: String)

        var errorDescription: String? {
            switch self {
            case .nestedPaths:
                return "The new folder can't be inside the old notes folder (or vice versa)."
            case .destinationNotWritable(let path):
                return "The folder \"\(path)\" isn't writable."
            case .insufficientSpace(let needed, let available):
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let a = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Not enough space to move your notes (need \(n), \(a) free)."
            case .verificationFailed(let item):
                return "Couldn't verify \"\(item)\" copied correctly; your notes were left where they are."
            }
        }
    }

    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "OutputFolderMigrator")

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Move every top-level item (including dotfiles) from `oldRaw` into `newRaw`.
    /// `newRaw` becomes the notes folder. No-op when the two resolve to the same path.
    @discardableResult
    func migrate(from oldRaw: URL, to newRaw: URL, strategy: Strategy = .auto) throws -> MigrationReport {
        let old = Self.normalize(oldRaw)
        let new = Self.normalize(newRaw)
        var report = MigrationReport()

        // No-op: unchanged.
        guard old.path != new.path else { return report }

        // Refuse nested relationships — a recursive self-move would corrupt the tree.
        if Self.isAncestor(old, of: new) || Self.isAncestor(new, of: old) {
            throw MigrationError.nestedPaths(old: old.path, new: new.path)
        }

        // Nothing to move if the source is missing or not a directory: just ensure the
        // destination exists and let the caller switch to it.
        var oldIsDir: ObjCBool = false
        let oldExists = fileManager.fileExists(atPath: old.path, isDirectory: &oldIsDir)
        guard oldExists, oldIsDir.boolValue else {
            try ensureDirectory(new)
            return report
        }

        try ensureDirectory(new)
        guard fileManager.isWritableFile(atPath: new.path) else {
            throw MigrationError.destinationNotWritable(new.path)
        }

        let useCopy: Bool
        switch strategy {
        case .move: useCopy = false
        case .copyVerifyDelete: useCopy = true
        case .auto: useCopy = !Self.sameVolume(old, new, fileManager: fileManager)
        }

        if useCopy {
            let needed = Self.directorySize(old, fileManager: fileManager)
            if let available = Self.availableCapacity(new), available < needed {
                throw MigrationError.insufficientSpace(needed: needed, available: available)
            }
        }

        try mergeChildren(of: old, into: new, useCopy: useCopy, destRoot: new, report: &report)

        // Move confirmed: drop the now-empty old folder. Left in place if anything remains
        // (e.g. a `.md` whose destination copy we deliberately kept on collision), so we
        // never remove a directory that still holds data.
        removeIfEmpty(old)
        return report
    }

    // MARK: - Per-item move / merge

    /// One directory level: pair each note with its sibling attachment folder
    /// FIRST (so the two can never diverge on collision, regardless of listing
    /// order), then merge the remaining singles. Includes hidden/dotfiles.
    private func mergeChildren(
        of sourceDir: URL,
        into destDir: URL,
        useCopy: Bool,
        destRoot: URL,
        report: inout MigrationReport
    ) throws {
        // Snapshot the listing before mutating.
        let children = try fileManager.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: []
        )
        let plan = Self.pairPlan(children: children, fileManager: fileManager)
        for pair in plan.pairs {
            try mergePair(pair, into: destDir, useCopy: useCopy, destRoot: destRoot, report: &report)
        }
        for single in plan.singles {
            let dest = destDir.appendingPathComponent(single.lastPathComponent)
            try mergeItem(at: single, to: dest, useCopy: useCopy, destRoot: destRoot, report: &report)
        }
    }

    /// Relocate `source` to `dest`, merging into an existing directory and disambiguating
    /// file collisions. Recurses for directory-into-directory merges.
    private func mergeItem(
        at source: URL,
        to dest: URL,
        useCopy: Bool,
        destRoot: URL,
        report: inout MigrationReport
    ) throws {
        var destIsDir: ObjCBool = false
        let destExists = fileManager.fileExists(atPath: dest.path, isDirectory: &destIsDir)

        if !destExists {
            try place(source, at: dest, useCopy: useCopy)
            return
        }

        var sourceIsDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDir)

        // Directory into directory: merge children (pair-aware), then drop the
        // now-empty source dir.
        if sourceIsDir.boolValue, destIsDir.boolValue {
            try mergeChildren(of: source, into: dest, useCopy: useCopy, destRoot: destRoot, report: &report)
            removeIfEmpty(source)
            return
        }

        // File collides with an existing CLAUDE.md config file: keep the destination.
        if !sourceIsDir.boolValue, !destIsDir.boolValue, Self.isPreserveOnCollision(dest) {
            Self.log.info("kept existing \(dest.lastPathComponent, privacy: .public); skipped incoming copy")
            return
        }

        // Any other collision (file↔file note, or file↔dir type mismatch): never overwrite.
        let unique = uniqueURL(for: dest, sourceIsDirectory: sourceIsDir.boolValue)
        Self.log.info("collision on \(dest.lastPathComponent, privacy: .public); placed as \(unique.lastPathComponent, privacy: .public)")
        try place(source, at: unique, useCopy: useCopy)
        if !sourceIsDir.boolValue, Self.isNoteExtension(dest.pathExtension) {
            report.renamedNotes[CaptureContract.relativePath(of: dest, in: destRoot)] =
                CaptureContract.relativePath(of: unique, in: destRoot)
        }
    }

    /// Relocate a note + attachment-folder pair as one unit: the destination base
    /// name is free only when BOTH `<base>.<ext>` and `<base>/` are free (the same
    /// predicate `FileWriter.uniqueDestination` used to create them), so on
    /// collision both members rename to `<base>-<n>` in lockstep and the moved
    /// note's footer links are rewritten to the renamed folder. A paired
    /// attachment dir never takes the dir-into-dir merge path — merging it into a
    /// different note's folder is exactly the cross-wiring this prevents.
    private func mergePair(
        _ pair: (note: URL, dir: URL),
        into destDir: URL,
        useCopy: Bool,
        destRoot: URL,
        report: inout MigrationReport
    ) throws {
        let ext = pair.note.pathExtension
        let base = pair.note.deletingPathExtension().lastPathComponent
        let (noteDest, folderName) = uniquePairDestination(in: destDir, baseName: base, fileExtension: ext)
        let dirDest = destDir.appendingPathComponent(folderName, isDirectory: true)

        try place(pair.note, at: noteDest, useCopy: useCopy)
        try place(pair.dir, at: dirDest, useCopy: useCopy)

        guard folderName != base else { return }
        Self.log.info("pair collision on \(base, privacy: .public); placed as \(folderName, privacy: .public)")
        rewriteFooter(at: noteDest, from: base, to: folderName)
        if Self.isNoteExtension(ext) {
            let intended = destDir.appendingPathComponent(base + "." + ext)
            report.renamedNotes[CaptureContract.relativePath(of: intended, in: destRoot)] =
                CaptureContract.relativePath(of: noteDest, in: destRoot)
        }
    }

    /// Rewrites the placed note's footer links after a lockstep rename. Best
    /// effort: a failure leaves a stale (dangling but honest) footer, never data
    /// loss — the note and its attachments are already safely placed.
    private func rewriteFooter(at noteURL: URL, from oldFolder: String, to newFolder: String) {
        do {
            let data = try Data(contentsOf: noteURL)
            let text = String(decoding: data, as: UTF8.self)
            let rewritten: String?
            if noteURL.pathExtension.lowercased() == "md" {
                rewritten = CaptureContract.rewriteFooterFolder(inMarkdown: text, from: oldFolder, to: newFolder)
            } else {
                rewritten = CaptureContract.rewriteFooterFolder(inPlainText: text, from: oldFolder, to: newFolder)
            }
            guard let rewritten else { return }
            try AtomicFile.write(Data(rewritten.utf8), to: noteURL)
        } catch {
            Self.log.warning("couldn't rewrite footer of \(noteURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pair planning

    /// Splits a directory listing into note+attachment-folder pairs and singles.
    /// A pair is a regular `<base>.md`/`<base>.txt` file plus a sibling directory
    /// named exactly `<base>` — the convention `FileWriter.uniqueDestination`
    /// guarantees for app-written notes. `CLAUDE.md` never pairs (it is config,
    /// preserved-on-collision, not a note).
    static func pairPlan(
        children: [URL],
        fileManager: FileManager
    ) -> (pairs: [(note: URL, dir: URL)], singles: [URL]) {
        var files: [URL] = []
        var dirsByName: [String: URL] = [:]
        var order: [URL] = []

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            order.append(child)
            if isDir.boolValue {
                dirsByName[child.lastPathComponent] = child
            } else {
                files.append(child)
            }
        }

        var pairs: [(note: URL, dir: URL)] = []
        var pairedMembers = Set<String>()
        for file in files {
            guard isNoteExtension(file.pathExtension), !isPreserveOnCollision(file) else { continue }
            let base = file.deletingPathExtension().lastPathComponent
            guard let dir = dirsByName[base], !pairedMembers.contains(base) else { continue }
            pairs.append((note: file, dir: dir))
            pairedMembers.insert(base)
            pairedMembers.insert(file.lastPathComponent)
        }

        let singles = order.filter { !pairedMembers.contains($0.lastPathComponent) }
        return (pairs, singles)
    }

    static func isNoteExtension(_ ext: String) -> Bool {
        ["md", "txt"].contains(ext.lowercased())
    }

    /// Dual collision walk for a pair: candidate base is free only when both the
    /// note path and the directory path are free at the destination.
    private func uniquePairDestination(
        in folder: URL,
        baseName: String,
        fileExtension: String
    ) -> (noteURL: URL, folderName: String) {
        var candidate = baseName
        var suffix = 1
        while true {
            let file = folder.appendingPathComponent(candidate + "." + fileExtension)
            let dir = folder.appendingPathComponent(candidate, isDirectory: true)
            if !fileManager.fileExists(atPath: file.path), !fileManager.fileExists(atPath: dir.path) {
                return (file, candidate)
            }
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
    }

    /// Move or copy-verify-delete a single item (file or whole subtree) into a free path.
    private func place(_ source: URL, at dest: URL, useCopy: Bool) throws {
        if useCopy {
            try fileManager.copyItem(at: source, to: dest)
            try verify(source: source, dest: dest)
            try fileManager.removeItem(at: source)
        } else {
            try fileManager.moveItem(at: source, to: dest)
        }
    }

    /// Recursively confirm `dest` mirrors `source` (existence + file sizes) before the
    /// source is deleted on the cross-volume path.
    private func verify(source: URL, dest: URL) throws {
        var sourceIsDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDir)

        var destIsDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dest.path, isDirectory: &destIsDir) else {
            throw MigrationError.verificationFailed(item: dest.lastPathComponent)
        }

        if sourceIsDir.boolValue {
            guard destIsDir.boolValue else {
                throw MigrationError.verificationFailed(item: dest.lastPathComponent)
            }
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
            for child in children {
                try verify(source: child, dest: dest.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            guard Self.fileSize(source, fileManager) == Self.fileSize(dest, fileManager) else {
                throw MigrationError.verificationFailed(item: dest.lastPathComponent)
            }
        }
    }

    // MARK: - Helpers

    /// `CLAUDE.md` is config the user curates in the destination; on collision we keep
    /// the destination copy rather than overwrite it. Deliberately narrow: with built-in
    /// triage, ordinary `.md` files are *notes*, and preserving any colliding `.md` would
    /// silently strand a captured note in the old folder. Notes take the `-<n>`
    /// disambiguation path instead.
    static func isPreserveOnCollision(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == "claude.md"
    }

    /// Free path next to `dest` using the `<base>-<n>` scheme (mirrors `FileWriter.uniqueDestination`).
    /// Extension semantics follow the **source** item: a directory is extensionless
    /// even when its name contains periods (`Notes v1.2` → `Notes v1.2-1`, never
    /// `Notes v1-1.2` — `pathExtension` can't know the URL is a directory).
    private func uniqueURL(for dest: URL, sourceIsDirectory: Bool) -> URL {
        guard fileManager.fileExists(atPath: dest.path) else { return dest }
        let dir = dest.deletingLastPathComponent()
        let ext = sourceIsDirectory ? "" : dest.pathExtension
        let base = sourceIsDirectory
            ? dest.lastPathComponent
            : dest.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The migrator's only directory removal. Delegates to the single guarded primitive
    /// so an empty source folder is dropped but one that still holds data (e.g. a `.md`
    /// kept on collision) is never removed.
    private func removeIfEmpty(_ url: URL) {
        FileSafety.removeIfEmpty(url, fileManager: fileManager)
    }

    static func normalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// True when `ancestor` strictly contains `descendant` (component-wise prefix).
    static func isAncestor(_ ancestor: URL, of descendant: URL) -> Bool {
        let a = normalize(ancestor).pathComponents
        let d = normalize(descendant).pathComponents
        guard d.count > a.count else { return false }
        return Array(d.prefix(a.count)) == a
    }

    static func sameVolume(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
        // `volumeIdentifier` is an opaque `any Hashable & Sendable`; the concrete value is
        // an NSObject, so compare via that for equality.
        let av = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
        let bv = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
        guard let av, let bv else { return false }  // unknown → take the safer copy path
        return av == bv
    }

    static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func availableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func fileSize(_ url: URL, _ fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
