import Foundation

struct PersistedState: Codable, Sendable, Equatable {
    var chatDbWatermark: Int64
    var selfHandlesCacheTs: Date?
    var lastError: String?

    init(
        chatDbWatermark: Int64 = 0,
        selfHandlesCacheTs: Date? = nil,
        lastError: String? = nil
    ) {
        self.chatDbWatermark = chatDbWatermark
        self.selfHandlesCacheTs = selfHandlesCacheTs
        self.lastError = lastError
    }
}
