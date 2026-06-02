import XCTest
@testable import Rapture

final class AttributedBodyDecoderTests: XCTestCase {
    private func fixture(filler: Data = Data([0x01, 0x02, 0x03]), lengthPrefix: [UInt8], payload: Data) -> Data {
        var data = Data([0xAA, 0xBB])
        data.append("NSString".data(using: .utf8)!)
        data.append(0x00)
        data.append(filler)
        data.append(0x2B)
        data.append(contentsOf: lengthPrefix)
        data.append(payload)
        data.append(Data([0xCC, 0xDD]))
        return data
    }

    func testShortASCII() {
        let text = "verification one"
        let payload = Data(text.utf8)
        let blob = fixture(lengthPrefix: [UInt8(payload.count)], payload: payload)
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), text)
    }

    func testLongTextWith0x81Escape() {
        let text = String(repeating: "rent is due on the 5th. ", count: 10)
        let payload = Data(text.utf8)
        XCTAssertGreaterThan(payload.count, 127)
        XCTAssertLessThanOrEqual(payload.count, 255)
        let blob = fixture(lengthPrefix: [0x81, UInt8(payload.count)], payload: payload)
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), text)
    }

    func testMultiByteUTF8WithEmoji() {
        let text = "rent 🏠 is due 5️⃣"
        let payload = Data(text.utf8)
        XCTAssertGreaterThan(payload.count, text.count)
        let blob = fixture(lengthPrefix: [UInt8(payload.count)], payload: payload)
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), text)
    }

    func testReturnsNilOnMissingMarker() {
        let bogus = Data([0x00, 0x2B, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertNil(AttributedBodyDecoder.decode(bogus))
    }

    func testReturnsNilOnLengthOverflow() {
        let blob = fixture(lengthPrefix: [0x82, 0xFF, 0xFF], payload: Data([0x68, 0x69]))
        XCTAssertNil(AttributedBodyDecoder.decode(blob))
    }

    func testReturnsNilOnEmptyInput() {
        XCTAssertNil(AttributedBodyDecoder.decode(Data()))
        XCTAssertNil(AttributedBodyDecoder.decode(nil))
    }

    func testTwoByteLengthEscape() {
        let text = String(repeating: "x", count: 300)
        let payload = Data(text.utf8)
        let lo = UInt8(payload.count & 0xFF)
        let hi = UInt8((payload.count >> 8) & 0xFF)
        let blob = fixture(lengthPrefix: [0x82, lo, hi], payload: payload)
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), text)
    }
}
