import Foundation

struct Settings: Codable, Sendable, Equatable {
    var outputFolder: URL?
    var allowedHandles: [String]
    var allowSMS: Bool
    var launchAtLogin: Bool
    var paused: Bool
    var replyMode: ReplyMode
    /// When on, an *empty* output folder with no `CLAUDE.md` is seeded with a generic
    /// starter scaffold (template `CLAUDE.md` + `processed/` + `in-progress/`). Off by
    /// default and strictly non-destructive — see `OutputFolderScaffold`.
    var seedScaffold: Bool

    init(
        outputFolder: URL? = nil,
        allowedHandles: [String] = [],
        allowSMS: Bool = false,
        launchAtLogin: Bool = true,
        paused: Bool = false,
        replyMode: ReplyMode = .all,
        seedScaffold: Bool = false
    ) {
        self.outputFolder = outputFolder
        self.allowedHandles = allowedHandles
        self.allowSMS = allowSMS
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.replyMode = replyMode
        self.seedScaffold = seedScaffold
    }

    enum CodingKeys: String, CodingKey {
        case outputFolder, allowedHandles, allowSMS, launchAtLogin, paused, replyMode, seedScaffold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputFolder = try c.decodeIfPresent(URL.self, forKey: .outputFolder)
        allowedHandles = try c.decodeIfPresent([String].self, forKey: .allowedHandles) ?? []
        allowSMS = try c.decodeIfPresent(Bool.self, forKey: .allowSMS) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        replyMode = try c.decodeIfPresent(ReplyMode.self, forKey: .replyMode) ?? .all
        // Absent in pre-existing settings.json → default off, so older files round-trip.
        seedScaffold = try c.decodeIfPresent(Bool.self, forKey: .seedScaffold) ?? false
    }
}
