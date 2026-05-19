import Foundation

struct AttachmentRef: Hashable, Codable, Sendable {
    let sourcePath: String
    let mimeType: String?
    let transferName: String?
}
