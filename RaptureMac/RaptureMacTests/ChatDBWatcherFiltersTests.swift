import XCTest
@testable import Rapture

final class ChatDBWatcherFiltersTests: XCTestCase {

    // MARK: - isLinkPreviewPayload — exclude iMessage rich-link metadata

    func testRecognizesPluginPayloadAttachmentByFilename() {
        XCTAssertTrue(ChatDBWatcher.isLinkPreviewPayload(
            filename: "182E0161-3020-4439-AF7E-660A2150D01B.pluginPayloadAttachment",
            transferName: nil
        ))
    }

    func testRecognizesPluginPayloadAttachmentByTransferName() {
        // The transfer_name column carries the original filename in some chat.db schemas.
        // We defend on both.
        XCTAssertTrue(ChatDBWatcher.isLinkPreviewPayload(
            filename: nil,
            transferName: "182E0161-3020-4439-AF7E-660A2150D01B.pluginPayloadAttachment"
        ))
    }

    func testRecognizesPathPrefixedPluginPayload() {
        // Real chat.db filenames are absolute or ~-prefixed paths; the suffix is what
        // matters.
        XCTAssertTrue(ChatDBWatcher.isLinkPreviewPayload(
            filename: "~/Library/Messages/Attachments/ab/12/FFB6443D-…/preview.pluginPayloadAttachment",
            transferName: nil
        ))
    }

    func testIgnoresRealAttachmentFilenames() {
        // Photos, videos, audio, documents are preserved.
        XCTAssertFalse(ChatDBWatcher.isLinkPreviewPayload(
            filename: "~/Library/Messages/Attachments/aa/00/IMG_1234.jpeg",
            transferName: "IMG_1234.jpeg"
        ))
        XCTAssertFalse(ChatDBWatcher.isLinkPreviewPayload(
            filename: "~/Library/Messages/Attachments/aa/00/voice.caf",
            transferName: "voice.caf"
        ))
        XCTAssertFalse(ChatDBWatcher.isLinkPreviewPayload(
            filename: "~/Library/Messages/Attachments/aa/00/Document.pdf",
            transferName: "Document.pdf"
        ))
    }

    func testHandlesBothNilGracefully() {
        // Defensive: an attachment row with neither filename nor transfer_name shouldn't crash.
        XCTAssertFalse(ChatDBWatcher.isLinkPreviewPayload(filename: nil, transferName: nil))
    }

    func testDoesNotMatchSubstringElsewhere() {
        // "pluginPayloadAttachment" appearing mid-string (e.g., a folder named that way)
        // shouldn't trigger. Suffix-only match.
        XCTAssertFalse(ChatDBWatcher.isLinkPreviewPayload(
            filename: "~/Library/Messages/Attachments/pluginPayloadAttachment-stuff/real.jpeg",
            transferName: "real.jpeg"
        ))
    }
}
