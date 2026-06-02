import XCTest
@testable import Rapture

final class FileWriterSanitizationTests: XCTestCase {

    func testPassesNormalNameThrough() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("IMG_1234.jpeg"), "IMG_1234.jpeg")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("Photo on 2026-05-19.jpg"), "Photo on 2026-05-19.jpg")
    }

    func testStripsRelativeTraversal() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("../evil.sh"), "evil.sh")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("../../../etc/passwd"), "passwd")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("./hidden.txt"), "hidden.txt")
    }

    func testStripsAbsoluteRoots() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("/etc/passwd"), "passwd")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("/tmp/exfil.bin"), "exfil.bin")
    }

    func testFallsBackForDotOnlyNames() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename(".."), "attachment")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("."), "attachment")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename(""), "attachment")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("   "), "attachment")
    }

    func testStripsNullBytes() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("file\u{0000}.txt"), "file.txt")
    }

    func testCollapsesPathSeparatorRemnants() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("dir:subdir"), "dir_subdir")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("a:b:c"), "a_b_c")
    }

    func testPreservesUnicode() {
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("résumé.pdf"), "résumé.pdf")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("写真.jpg"), "写真.jpg")
        XCTAssertEqual(FileWriter.sanitizeAttachmentFilename("📸-photo.heic"), "📸-photo.heic")
    }
}
