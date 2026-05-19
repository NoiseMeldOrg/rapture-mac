import Foundation

struct PersistedState: Codable, Sendable, Equatable {
    var chatDbWatermark: Int64
    var selfHandlesCacheTs: Date?
    var lastError: String?
    var recentSentEchoes: [EchoEntry]
    var automationPrePromptShown: Bool
    var todayCount: Int
    var todayDate: Date?
    var lastCaptureAt: Date?

    init(
        chatDbWatermark: Int64 = 0,
        selfHandlesCacheTs: Date? = nil,
        lastError: String? = nil,
        recentSentEchoes: [EchoEntry] = [],
        automationPrePromptShown: Bool = false,
        todayCount: Int = 0,
        todayDate: Date? = nil,
        lastCaptureAt: Date? = nil
    ) {
        self.chatDbWatermark = chatDbWatermark
        self.selfHandlesCacheTs = selfHandlesCacheTs
        self.lastError = lastError
        self.recentSentEchoes = recentSentEchoes
        self.automationPrePromptShown = automationPrePromptShown
        self.todayCount = todayCount
        self.todayDate = todayDate
        self.lastCaptureAt = lastCaptureAt
    }

    enum CodingKeys: String, CodingKey {
        case chatDbWatermark
        case selfHandlesCacheTs
        case lastError
        case recentSentEchoes
        case automationPrePromptShown
        case todayCount
        case todayDate
        case lastCaptureAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chatDbWatermark = try c.decodeIfPresent(Int64.self, forKey: .chatDbWatermark) ?? 0
        self.selfHandlesCacheTs = try c.decodeIfPresent(Date.self, forKey: .selfHandlesCacheTs)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.recentSentEchoes = try c.decodeIfPresent([EchoEntry].self, forKey: .recentSentEchoes) ?? []
        self.automationPrePromptShown = try c.decodeIfPresent(Bool.self, forKey: .automationPrePromptShown) ?? false
        self.todayCount = try c.decodeIfPresent(Int.self, forKey: .todayCount) ?? 0
        self.todayDate = try c.decodeIfPresent(Date.self, forKey: .todayDate)
        self.lastCaptureAt = try c.decodeIfPresent(Date.self, forKey: .lastCaptureAt)
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
