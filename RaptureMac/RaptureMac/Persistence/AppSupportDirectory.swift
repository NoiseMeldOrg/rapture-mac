import Foundation

enum AppSupportDirectory {
    /// DEBUG builds use a separate Application Support container and a separate default
    /// notes folder so development/manual testing can never read, write, or relocate the
    /// real installed app's `settings.json`, `state.json`, sidecar, or notes. This is the
    /// root-cause fix for the 2026-06-22 incident, where a shared container forced
    /// hand-editing the production settings during a relocate test and the real folder was
    /// deleted as collateral. See `agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/`.
    #if DEBUG
    static let folderName = "Rapture for Mac (Debug)"
    /// True when this build uses the isolated debug containers (surfaced in the UI marker).
    static let isDebugContainer = true
    #else
    static let folderName = "Rapture for Mac"
    static let isDebugContainer = false
    #endif

    static func url() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var defaultOutputFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        #if DEBUG
        // Sandboxed default so an unconfigured debug build never lands on the real folder.
        return docs.appendingPathComponent("Rapture Notes (Debug)", isDirectory: true)
        #else
        return docs.appendingPathComponent("Rapture Notes", isDirectory: true)
        #endif
    }
}
