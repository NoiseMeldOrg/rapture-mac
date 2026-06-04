import XCTest
@testable import Rapture

final class IntegrationDiscoveryTests: XCTestCase {

    private var tempRoot: URL!
    private var examplesRoot: URL!
    private var scriptsRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath() canonicalizes /var/folders → /private/var/folders the same way
        // FileManager.contentsOfDirectory does. URL.resolvingSymlinksInPath and
        // NSString.resolvingSymlinksInPath do not.
        let resolved = realpath(base.path, nil)!
        tempRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        examplesRoot = tempRoot.appendingPathComponent("examples", isDirectory: true)
        scriptsRoot = tempRoot.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: examplesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func makeFolder(_ name: String) throws -> URL {
        let url = examplesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func discover() throws -> [ConsumerCard] {
        try IntegrationDiscovery.discover(examplesRoot: examplesRoot, scriptsRoot: scriptsRoot)
    }

    // MARK: - Basics

    func testEmptyExamplesRootReturnsEmptyList() throws {
        XCTAssertEqual(try discover(), [])
    }

    func testThrowsWhenExamplesRootDoesNotExist() {
        let bogus = tempRoot.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try IntegrationDiscovery.discover(examplesRoot: bogus, scriptsRoot: scriptsRoot))
    }

    func testSkipsHiddenEntries() throws {
        _ = try makeFolder(".hidden-folder")
        try writeFile("ignored", to: examplesRoot.appendingPathComponent(".DS_Store"))
        _ = try makeFolder("visible")
        let cards = try discover()
        XCTAssertEqual(cards.map(\.id), ["visible"])
    }

    func testSkipsNonDirectoryEntries() throws {
        try writeFile("stray", to: examplesRoot.appendingPathComponent("loose-file.txt"))
        _ = try makeFolder("real-folder")
        let cards = try discover()
        XCTAssertEqual(cards.map(\.id), ["real-folder"])
    }

    func testCardsSortAlphabeticallyByFolderName() throws {
        _ = try makeFolder("zebra")
        _ = try makeFolder("alpha")
        _ = try makeFolder("middle")
        let cards = try discover()
        XCTAssertEqual(cards.map(\.id), ["alpha", "middle", "zebra"])
    }

    // MARK: - Filesystem-derived defaults

    func testDisplayNameDerivedFromFolderName() throws {
        _ = try makeFolder("claude-code")
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.displayName, "Claude Code")
    }

    func testDescriptionDerivedFromReadmeFirstParagraphAfterH1() throws {
        let folder = try makeFolder("demo")
        try writeFile("""
        # Demo header

        First paragraph after the H1 that describes what this does.

        Second paragraph should not be included.
        """, to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "First paragraph after the H1 that describes what this does.")
    }

    func testDescriptionJoinsMultiLineParagraph() throws {
        let folder = try makeFolder("demo")
        try writeFile("""
        # Demo

        Line one
        wraps onto line two
        and three.

        Next paragraph.
        """, to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "Line one wraps onto line two and three.")
    }

    func testDescriptionEmptyWhenReadmeMissing() throws {
        _ = try makeFolder("no-readme")
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "")
    }

    func testDescriptionFallsBackToFirstParagraphWhenNoH1() throws {
        let folder = try makeFolder("no-h1")
        try writeFile("First paragraph with no heading.\n\nSecond paragraph.", to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "First paragraph with no heading.")
    }

    func testDescriptionStopsAtNextHeading() throws {
        let folder = try makeFolder("h2-stops")
        try writeFile("""
        # Demo

        ## Subsection right after the H1
        """, to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "")
    }

    func testDefaultDocsListIncludesReadmeWhenPresent() throws {
        let folder = try makeFolder("with-readme")
        try writeFile("# H\n\nx", to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.docs.map(\.label), ["README"])
        XCTAssertEqual(card.docs.first?.fileURL, folder.appendingPathComponent("README.md"))
    }

    func testDefaultDocsListEmptyWhenNoReadme() throws {
        _ = try makeFolder("no-docs")
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.docs, [])
    }

    func testInstallsDefaultEmptyWithoutManifest() throws {
        _ = try makeFolder("no-installs")
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.installs, [])
    }

    // MARK: - Manifest override

    func testManifestDisplayNameOverridesPrettifiedFolderName() throws {
        let folder = try makeFolder("cli")
        try writeFile(#"{"displayName": "Generic CLI"}"#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.displayName, "Generic CLI")
    }

    func testManifestDescriptionOverridesReadmeDerivation() throws {
        let folder = try makeFolder("override-desc")
        try writeFile("# H\n\nfrom readme.", to: folder.appendingPathComponent("README.md"))
        try writeFile(#"{"description": "manifest description wins"}"#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.description, "manifest description wins")
    }

    func testManifestDocsReplaceDefault() throws {
        let folder = try makeFolder("custom-docs")
        try writeFile("# H\n\nx", to: folder.appendingPathComponent("README.md"))
        try writeFile("# child\n\nx", to: folder.appendingPathComponent("CHILD.md"))
        try writeFile(#"""
        {
          "docs": [
            {"label": "Overview", "file": "README.md"},
            {"label": "Child", "file": "CHILD.md"}
          ]
        }
        """#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.docs.map(\.label), ["Overview", "Child"])
        XCTAssertEqual(card.docs[1].fileURL, folder.appendingPathComponent("CHILD.md"))
    }

    func testMalformedManifestFallsBackToFilesystemDefaults() throws {
        let folder = try makeFolder("broken-json")
        try writeFile("{ not valid json", to: folder.appendingPathComponent("manifest.json"))
        try writeFile("# H\n\nfallback description.", to: folder.appendingPathComponent("README.md"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.displayName, "Broken Json")
        XCTAssertEqual(card.description, "fallback description.")
        XCTAssertEqual(card.docs.map(\.label), ["README"])
    }

    // MARK: - Install profiles

    func testParsesClaudeCodeManifestWithHookInstall() throws {
        let folder = try makeFolder("claude-code")
        try writeFile(#"""
        {
          "displayName": "Claude Code",
          "description": "triage",
          "installs": [
            {
              "id": "claude-hook",
              "name": "SessionStart hook",
              "description": "opportunistic",
              "install": "Scripts/install-claude-hook.sh",
              "uninstall": "Scripts/uninstall-claude-hook.sh",
              "statusKey": "hook",
              "requires": {"cli": ["claude", "jq"]}
            }
          ]
        }
        """#, to: folder.appendingPathComponent("manifest.json"))

        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.installs.count, 1)

        let hook = card.installs[0]
        XCTAssertEqual(hook.id, "claude-hook")
        XCTAssertEqual(hook.statusKey, .hook)
        XCTAssertEqual(hook.install, scriptsRoot.appendingPathComponent("install-claude-hook.sh"))
        XCTAssertEqual(hook.uninstall, scriptsRoot.appendingPathComponent("uninstall-claude-hook.sh"))
        XCTAssertEqual(hook.requires.cli, ["claude", "jq"])
        XCTAssertEqual(hook.requires.tcc, [])
        XCTAssertTrue(hook.config.isEmpty)
        XCTAssertNil(hook.configFile)
        XCTAssertNil(hook.start)
        XCTAssertNil(hook.stop)
        XCTAssertNil(hook.restart)
        XCTAssertTrue(hook.logs.isEmpty)
    }

    func testInstallWithoutIdOrNameIsSkipped() throws {
        let folder = try makeFolder("missing-fields")
        try writeFile(#"""
        {
          "installs": [
            {"id": "ok", "name": "OK install"},
            {"name": "Has name no id"},
            {"id": "has-id-no-name"}
          ]
        }
        """#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.installs.map(\.id), ["ok"])
    }

    func testUnknownStatusKeyIsPreserved() throws {
        let folder = try makeFolder("future-consumer")
        try writeFile(#"""
        {
          "installs": [
            {"id": "x", "name": "X", "statusKey": "openclaw"}
          ]
        }
        """#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.installs.first?.statusKey, .unknown("openclaw"))
    }

    func testUnknownConfigTypeDefaultsToString() throws {
        let folder = try makeFolder("bad-type")
        try writeFile(#"""
        {
          "installs": [
            {"id": "x", "name": "X", "config": [{"key": "K", "label": "L", "type": "totally-made-up"}]}
          ]
        }
        """#, to: folder.appendingPathComponent("manifest.json"))
        let card = try XCTUnwrap(try discover().first)
        XCTAssertEqual(card.installs.first?.config.first?.kind, .string)
    }

    // MARK: - Path resolution

    func testResolvePathAbsolute() {
        let url = IntegrationDiscovery.resolvePath("/etc/hosts", folder: examplesRoot, scriptsRoot: scriptsRoot)
        XCTAssertEqual(url, URL(fileURLWithPath: "/etc/hosts"))
    }

    func testResolvePathTildeExpands() {
        let url = IntegrationDiscovery.resolvePath("~/foo/bar", folder: examplesRoot, scriptsRoot: scriptsRoot)
        XCTAssertFalse(url.path.hasPrefix("~"))
        XCTAssertTrue(url.path.hasSuffix("/foo/bar"))
    }

    func testResolvePathScriptsPrefix() {
        let url = IntegrationDiscovery.resolvePath("Scripts/install.sh", folder: examplesRoot, scriptsRoot: scriptsRoot)
        XCTAssertEqual(url, scriptsRoot.appendingPathComponent("install.sh"))
    }

    func testResolvePathBareRelative() {
        let folder = examplesRoot.appendingPathComponent("c")
        let url = IntegrationDiscovery.resolvePath("SKILL.md", folder: folder, scriptsRoot: scriptsRoot)
        XCTAssertEqual(url, folder.appendingPathComponent("SKILL.md"))
    }

    // MARK: - Prettify

    func testPrettifySingleWord() {
        XCTAssertEqual(IntegrationDiscovery.prettify("hermes"), "Hermes")
    }

    func testPrettifyKebabCase() {
        XCTAssertEqual(IntegrationDiscovery.prettify("claude-code"), "Claude Code")
    }

    func testPrettifyAcronymStaysLowercase() {
        // 'cli' becomes 'Cli'; spec acknowledges this and recommends a manifest override.
        XCTAssertEqual(IntegrationDiscovery.prettify("cli"), "Cli")
    }

    func testPrettifyMultiSegment() {
        XCTAssertEqual(IntegrationDiscovery.prettify("a-b-c-d"), "A B C D")
    }
}
