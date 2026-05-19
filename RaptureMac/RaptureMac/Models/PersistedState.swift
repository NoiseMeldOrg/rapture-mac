import Foundation

struct PersistedState: Codable, Sendable, Equatable {
    var chatDbWatermark: Int64
    var selfHandlesCacheTs: Date?
    var lastError: String?
    var recentSentEchoes: [EchoEntry]
    var automationPrePromptShown: Bool

    init(
        chatDbWatermark: Int64 = 0,
        selfHandlesCacheTs: Date? = nil,
        lastError: String? = nil,
        recentSentEchoes: [EchoEntry] = [],
        automationPrePromptShown: Bool = false
    ) {
        self.chatDbWatermark = chatDbWatermark
        self.selfHandlesCacheTs = selfHandlesCacheTs
        self.lastError = lastError
        self.recentSentEchoes = recentSentEchoes
        self.automationPrePromptShown = automationPrePromptShown
    }

    enum CodingKeys: String, CodingKey {
        case chatDbWatermark
        case selfHandlesCacheTs
        case lastError
        case recentSentEchoes
        case automationPrePromptShown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chatDbWatermark = try c.decodeIfPresent(Int64.self, forKey: .chatDbWatermark) ?? 0
        self.selfHandlesCacheTs = try c.decodeIfPresent(Date.self, forKey: .selfHandlesCacheTs)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.recentSentEchoes = try c.decodeIfPresent([EchoEntry].self, forKey: .recentSentEchoes) ?? []
        self.automationPrePromptShown = try c.decodeIfPresent(Bool.self, forKey: .automationPrePromptShown) ?? false
    }
}
