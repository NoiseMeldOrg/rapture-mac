import XCTest
import SwiftUI
@testable import Rapture

@MainActor
final class WatcherConfigStoreTests: XCTestCase {

    private var tempFile: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatcherConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempFile = base.appendingPathComponent("watch.env")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
    }

    // MARK: - Parse

    func testParseSimpleKeyValue() {
        let result = WatcherConfigStore.parse("FOO=bar\nBAZ=qux")
        XCTAssertEqual(result, ["FOO": "bar", "BAZ": "qux"])
    }

    func testParseSkipsBlankLines() {
        let result = WatcherConfigStore.parse("\n\nFOO=bar\n\n")
        XCTAssertEqual(result, ["FOO": "bar"])
    }

    func testParseSkipsCommentLines() {
        let result = WatcherConfigStore.parse("""
        # This is a comment
        FOO=bar
        # Another comment
        BAZ=qux
        """)
        XCTAssertEqual(result, ["FOO": "bar", "BAZ": "qux"])
    }

    func testParseHandlesEmptyValue() {
        let result = WatcherConfigStore.parse("FOO=")
        XCTAssertEqual(result, ["FOO": ""])
    }

    func testParseHandlesValueWithEqualsSign() {
        let result = WatcherConfigStore.parse("URL=https://x.com?a=1")
        XCTAssertEqual(result, ["URL": "https://x.com?a=1"])
    }

    func testParseTrimsWhitespaceAroundKey() {
        let result = WatcherConfigStore.parse("  FOO  =bar")
        XCTAssertEqual(result, ["FOO": "bar"])
    }

    func testParseIgnoresMalformedLines() {
        let result = WatcherConfigStore.parse("not-an-assignment\nFOO=bar")
        XCTAssertEqual(result, ["FOO": "bar"])
    }

    func testParseIgnoresLineWithEmptyKey() {
        let result = WatcherConfigStore.parse("=bar\nFOO=baz")
        XCTAssertEqual(result, ["FOO": "baz"])
    }

    func testParseEmptyStringReturnsEmptyDict() {
        XCTAssertEqual(WatcherConfigStore.parse(""), [:])
    }

    // MARK: - Serialize

    func testSerializeSortsKeysAlphabetically() {
        let dict = ["ZZZ": "1", "AAA": "2", "MMM": "3"]
        let text = WatcherConfigStore.serialize(dict)
        XCTAssertEqual(text, "AAA=2\nMMM=3\nZZZ=1\n")
    }

    func testSerializeEmptyDictProducesEmptyString() {
        XCTAssertEqual(WatcherConfigStore.serialize([:]), "")
    }

    func testSerializeEndsWithNewline() {
        let text = WatcherConfigStore.serialize(["FOO": "bar"])
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testSerializeHandlesEmptyValue() {
        XCTAssertEqual(WatcherConfigStore.serialize(["FOO": ""]), "FOO=\n")
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllKeysAndValues() {
        let original = [
            "RAPTURE_CLAUDE_WORKDIR": "/Users/me/Source/foo",
            "RAPTURE_MEDIA_MODEL": "sonnet",
            "RAPTURE_TEXT_MODEL": "haiku"
        ]
        let text = WatcherConfigStore.serialize(original)
        let parsed = WatcherConfigStore.parse(text)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripDropsComments() {
        let withComments = """
        # leading comment
        FOO=bar
        # inline comment
        BAZ=qux
        """
        let parsed1 = WatcherConfigStore.parse(withComments)
        let text = WatcherConfigStore.serialize(parsed1)
        let parsed2 = WatcherConfigStore.parse(text)
        XCTAssertEqual(parsed1, parsed2)
        XCTAssertFalse(text.contains("#"))
    }

    // MARK: - Store integration

    func testStoreLoadsFromExistingFile() throws {
        try "PRE_EXISTING=value\n".data(using: .utf8)!.write(to: tempFile)
        let store = WatcherConfigStore(fileURL: tempFile)
        XCTAssertEqual(store.values, ["PRE_EXISTING": "value"])
    }

    func testStoreLoadsEmptyDictWhenFileMissing() {
        let store = WatcherConfigStore(fileURL: tempFile)
        XCTAssertEqual(store.values, [:])
    }

    func testStoreSetWritesAtomicallyToDisk() throws {
        let store = WatcherConfigStore(fileURL: tempFile)
        store.set("RAPTURE_CLAUDE_WORKDIR", "/Users/me/Source/x")
        let onDisk = try String(contentsOf: tempFile, encoding: .utf8)
        XCTAssertEqual(onDisk, "RAPTURE_CLAUDE_WORKDIR=/Users/me/Source/x\n")
    }

    func testStoreSetTwoKeysWritesBothSortedOnDisk() throws {
        let store = WatcherConfigStore(fileURL: tempFile)
        store.set("ZZZ", "last")
        store.set("AAA", "first")
        let onDisk = try String(contentsOf: tempFile, encoding: .utf8)
        XCTAssertEqual(onDisk, "AAA=first\nZZZ=last\n")
    }

    func testStoreOverwritesExistingKey() throws {
        let store = WatcherConfigStore(fileURL: tempFile)
        store.set("FOO", "v1")
        store.set("FOO", "v2")
        XCTAssertEqual(store.values, ["FOO": "v2"])
        let onDisk = try String(contentsOf: tempFile, encoding: .utf8)
        XCTAssertEqual(onDisk, "FOO=v2\n")
    }

    func testStoreRemoveDeletesKeyAndRewrites() throws {
        let store = WatcherConfigStore(fileURL: tempFile)
        store.set("A", "1")
        store.set("B", "2")
        store.remove("A")
        XCTAssertEqual(store.values, ["B": "2"])
        let onDisk = try String(contentsOf: tempFile, encoding: .utf8)
        XCTAssertEqual(onDisk, "B=2\n")
    }

    func testStoreCreatesParentDirectoryIfMissing() throws {
        let nested = tempFile.deletingLastPathComponent()
            .appendingPathComponent("nested/inner")
            .appendingPathComponent("watch.env")
        let store = WatcherConfigStore(fileURL: nested)
        store.set("X", "y")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testStoreReloadsAcrossInstances() throws {
        let store1 = WatcherConfigStore(fileURL: tempFile)
        store1.set("PERSISTED", "across")
        let store2 = WatcherConfigStore(fileURL: tempFile)
        XCTAssertEqual(store2.values, ["PERSISTED": "across"])
    }

    func testBindingReturnsEmptyStringForMissingKey() {
        let store = WatcherConfigStore(fileURL: tempFile)
        XCTAssertEqual(store.binding(forKey: "MISSING").wrappedValue, "")
    }

    func testBindingSetWritesThrough() {
        let store = WatcherConfigStore(fileURL: tempFile)
        store.binding(forKey: "K").wrappedValue = "v"
        XCTAssertEqual(store.values, ["K": "v"])
    }
}
