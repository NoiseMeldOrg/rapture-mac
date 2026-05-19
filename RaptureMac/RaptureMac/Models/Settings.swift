import Foundation

struct Settings: Codable, Sendable, Equatable {
    var outputFolder: URL?
    var allowedHandles: [String]
    var allowSMS: Bool
    var launchAtLogin: Bool
    var paused: Bool
    var replyMode: ReplyMode

    init(
        outputFolder: URL? = nil,
        allowedHandles: [String] = [],
        allowSMS: Bool = false,
        launchAtLogin: Bool = true,
        paused: Bool = false,
        replyMode: ReplyMode = .all
    ) {
        self.outputFolder = outputFolder
        self.allowedHandles = allowedHandles
        self.allowSMS = allowSMS
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.replyMode = replyMode
    }
}
