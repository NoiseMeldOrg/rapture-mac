import Foundation

struct PersistedState: Codable, Sendable, Equatable {
    var chatDbWatermark: Int64
    var selfHandlesCacheTs: Date?
    var lastError: String?
    var recentSentEchoes: [EchoEntry]
    var recentCaptureHashes: [CaptureHashEntry]
    var automationPrePromptShown: Bool
    var todayCount: Int
    var todayDate: Date?
    var lastCaptureAt: Date?
    var relayFiledRecords: [RelayFiledEntry]
    var triagedRecords: [TriagedEntry]
    var triageIntroShown: Bool
    /// Next spool item sequence number. Monotonic across the app's lifetime —
    /// must never reset when the spool drains, or item names would be reused and
    /// break both `SpoolFiledLedger` identity and same-second flush ordering.
    var spoolNextSeq: Int
    var spoolFiledRecords: [SpoolFiledEntry]
    var handoffRecords: [HandoffEntry]

    init(
        chatDbWatermark: Int64 = 0,
        selfHandlesCacheTs: Date? = nil,
        lastError: String? = nil,
        recentSentEchoes: [EchoEntry] = [],
        recentCaptureHashes: [CaptureHashEntry] = [],
        automationPrePromptShown: Bool = false,
        todayCount: Int = 0,
        todayDate: Date? = nil,
        lastCaptureAt: Date? = nil,
        relayFiledRecords: [RelayFiledEntry] = [],
        triagedRecords: [TriagedEntry] = [],
        triageIntroShown: Bool = false,
        spoolNextSeq: Int = 1,
        spoolFiledRecords: [SpoolFiledEntry] = [],
        handoffRecords: [HandoffEntry] = []
    ) {
        self.chatDbWatermark = chatDbWatermark
        self.selfHandlesCacheTs = selfHandlesCacheTs
        self.lastError = lastError
        self.recentSentEchoes = recentSentEchoes
        self.recentCaptureHashes = recentCaptureHashes
        self.automationPrePromptShown = automationPrePromptShown
        self.todayCount = todayCount
        self.todayDate = todayDate
        self.lastCaptureAt = lastCaptureAt
        self.relayFiledRecords = relayFiledRecords
        self.triagedRecords = triagedRecords
        self.triageIntroShown = triageIntroShown
        self.spoolNextSeq = spoolNextSeq
        self.spoolFiledRecords = spoolFiledRecords
        self.handoffRecords = handoffRecords
    }

    enum CodingKeys: String, CodingKey {
        case chatDbWatermark
        case selfHandlesCacheTs
        case lastError
        case recentSentEchoes
        case recentCaptureHashes
        case automationPrePromptShown
        case todayCount
        case todayDate
        case lastCaptureAt
        case relayFiledRecords
        case triagedRecords
        case triageIntroShown
        case spoolNextSeq
        case spoolFiledRecords
        case handoffRecords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chatDbWatermark = try c.decodeIfPresent(Int64.self, forKey: .chatDbWatermark) ?? 0
        self.selfHandlesCacheTs = try c.decodeIfPresent(Date.self, forKey: .selfHandlesCacheTs)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.recentSentEchoes = try c.decodeIfPresent([EchoEntry].self, forKey: .recentSentEchoes) ?? []
        self.recentCaptureHashes = try c.decodeIfPresent([CaptureHashEntry].self, forKey: .recentCaptureHashes) ?? []
        self.automationPrePromptShown = try c.decodeIfPresent(Bool.self, forKey: .automationPrePromptShown) ?? false
        self.todayCount = try c.decodeIfPresent(Int.self, forKey: .todayCount) ?? 0
        self.todayDate = try c.decodeIfPresent(Date.self, forKey: .todayDate)
        self.lastCaptureAt = try c.decodeIfPresent(Date.self, forKey: .lastCaptureAt)
        self.relayFiledRecords = try c.decodeIfPresent([RelayFiledEntry].self, forKey: .relayFiledRecords) ?? []
        self.triagedRecords = try c.decodeIfPresent([TriagedEntry].self, forKey: .triagedRecords) ?? []
        self.triageIntroShown = try c.decodeIfPresent(Bool.self, forKey: .triageIntroShown) ?? false
        self.spoolNextSeq = try c.decodeIfPresent(Int.self, forKey: .spoolNextSeq) ?? 1
        self.spoolFiledRecords = try c.decodeIfPresent([SpoolFiledEntry].self, forKey: .spoolFiledRecords) ?? []
        self.handoffRecords = try c.decodeIfPresent([HandoffEntry].self, forKey: .handoffRecords) ?? []
    }

    /// Returns todayCount when `todayDate` falls on the same calendar day as `now`; 0 otherwise.
    /// Pure so views can render without persisting a midnight rollover.
    func displayedTodayCount(at now: Date, calendar: Calendar = .current) -> Int {
        guard let day = todayDate, calendar.isDate(day, inSameDayAs: now) else { return 0 }
        return todayCount
    }

    /// Pure computation of the rollover-aware increment. Used by StateStore.recordSuccess and the test suite.
    static func incrementing(
        currentDate: Date?,
        currentCount: Int,
        at sample: Date,
        calendar: Calendar = .current
    ) -> (date: Date, count: Int) {
        if let prior = currentDate, calendar.isDate(prior, inSameDayAs: sample) {
            return (sample, currentCount + 1)
        }
        return (sample, 1)
    }
}
