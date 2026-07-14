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
    /// When on, the app watches the iCloud relay folder the Rapture iOS app writes into
    /// and files arrivals into the output folder. On by default: it is a no-op until the
    /// folder exists, and enabling the destination on the iPhone is the real opt-in.
    var relayEnabled: Bool
    /// How captures are filed: `.full` (Markdown capture contract, classified into
    /// subfolders — the product default, including for updaters) or `.raw` (plain `.txt`
    /// at the root, the pre-triage behavior). Never add raw values to `TriageMode`
    /// without lenient decoding here: an unknown value throws and would reset every
    /// setting to defaults.
    var triageMode: TriageMode
    /// When on, an unambiguous "remind me to…"-style dictation additionally creates an
    /// Apple Reminder (the note always files regardless). Off by default; enabling it
    /// drives the Reminders TCC request from Settings.
    var remindersHandoffEnabled: Bool
    /// When on, a stated appointment with date+time additionally creates a 1-hour
    /// Calendar event. Off by default; enabling it drives the Calendars TCC request.
    var calendarHandoffEnabled: Bool
    /// `calendarIdentifier` of the Reminders list receiving handoffs; nil = system default.
    var remindersListID: String?
    /// `calendarIdentifier` of the calendar receiving handoffs; nil = system default.
    var calendarID: String?
    /// When on, voice-note captures are classified/titled/formatted by an AI
    /// engine (Apple on-device when available, else the user's Anthropic key)
    /// before composing. Off by default. The API key itself lives in the
    /// Keychain (`KeychainStore`), NEVER in this file.
    var aiTriageEnabled: Bool
    /// When on, link captures are enriched best-effort after filing: YouTube
    /// transcripts / article extracts fetched into `Links/Media/`, the note
    /// renamed to the real title. Off by default; independent of `aiTriageEnabled`.
    var linkEnrichmentEnabled: Bool

    init(
        outputFolder: URL? = nil,
        allowedHandles: [String] = [],
        allowSMS: Bool = false,
        launchAtLogin: Bool = true,
        paused: Bool = false,
        replyMode: ReplyMode = .all,
        seedScaffold: Bool = false,
        relayEnabled: Bool = true,
        triageMode: TriageMode = .full,
        remindersHandoffEnabled: Bool = false,
        calendarHandoffEnabled: Bool = false,
        remindersListID: String? = nil,
        calendarID: String? = nil,
        aiTriageEnabled: Bool = false,
        linkEnrichmentEnabled: Bool = false
    ) {
        self.outputFolder = outputFolder
        self.allowedHandles = allowedHandles
        self.allowSMS = allowSMS
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.replyMode = replyMode
        self.seedScaffold = seedScaffold
        self.relayEnabled = relayEnabled
        self.triageMode = triageMode
        self.remindersHandoffEnabled = remindersHandoffEnabled
        self.calendarHandoffEnabled = calendarHandoffEnabled
        self.remindersListID = remindersListID
        self.calendarID = calendarID
        self.aiTriageEnabled = aiTriageEnabled
        self.linkEnrichmentEnabled = linkEnrichmentEnabled
    }

    enum CodingKeys: String, CodingKey {
        case outputFolder, allowedHandles, allowSMS, launchAtLogin, paused, replyMode, seedScaffold, relayEnabled, triageMode
        case remindersHandoffEnabled, calendarHandoffEnabled, remindersListID, calendarID, aiTriageEnabled
        case linkEnrichmentEnabled
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
        // Absent in pre-existing settings.json → default on (relay capture is opt-out).
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? true
        // Absent in pre-existing settings.json → full triage: updaters get the new
        // default too (locked product decision); .raw is the explicit escape hatch.
        // Decoded via raw String so an unknown value (newer build's case, hand-edit,
        // corruption) degrades to .full instead of throwing — a throw here would
        // silently reset EVERY setting to defaults via SettingsStore's nil fallback.
        let triageModeRaw = try c.decodeIfPresent(String.self, forKey: .triageMode)
        triageMode = triageModeRaw.flatMap(TriageMode.init(rawValue:)) ?? .full
        // Absent in pre-existing settings.json → both handoffs off (explicit opt-in;
        // enabling drives the TCC request from Settings, never from the pipeline).
        remindersHandoffEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersHandoffEnabled) ?? false
        calendarHandoffEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarHandoffEnabled) ?? false
        remindersListID = try c.decodeIfPresent(String.self, forKey: .remindersListID)
        calendarID = try c.decodeIfPresent(String.self, forKey: .calendarID)
        // Absent in pre-existing settings.json → AI off (explicit opt-in).
        aiTriageEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiTriageEnabled) ?? false
        // Absent in pre-existing settings.json → enrichment off (explicit opt-in).
        linkEnrichmentEnabled = try c.decodeIfPresent(Bool.self, forKey: .linkEnrichmentEnabled) ?? false
    }
}
