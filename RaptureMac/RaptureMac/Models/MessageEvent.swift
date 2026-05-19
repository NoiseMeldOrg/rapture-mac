import Foundation

struct MessageEvent: Hashable, Sendable {
    static let appleEpochOffsetSeconds: TimeInterval = 978_307_200

    let rowid: Int64
    let guid: String
    let text: String?
    let attributedBody: Data?
    let dateAppleNs: Int64
    let isFromMe: Bool
    let cacheHasAttachments: Bool
    let service: String
    let handleId: String?
    let chatGuid: String?
    let chatStyle: Int?
    let attachments: [AttachmentRef]

    var dateUTC: Date {
        Date(timeIntervalSince1970: Self.appleEpochOffsetSeconds + Double(dateAppleNs) / 1_000_000_000)
    }
}
