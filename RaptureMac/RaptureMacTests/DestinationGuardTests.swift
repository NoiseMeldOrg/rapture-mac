import XCTest
@testable import Rapture

final class DestinationGuardTests: XCTestCase {

    private func classify(
        _ path: String,
        existing: Set<String>,
        volumeRoots: Set<String> = []
    ) -> DestinationGuard.Check {
        DestinationGuard.classify(
            path: path,
            directoryExists: { existing.contains($0) },
            isVolumeRoot: { volumeRoots.contains($0) }
        )
    }

    // MARK: - Available

    func testExistingFolderIsAvailable() {
        XCTAssertEqual(
            classify("/Users/me/Documents/Rapture Notes", existing: ["/Users/me/Documents/Rapture Notes"]),
            .available
        )
    }

    func testExistingFolderOnMountedVolumeIsAvailable() {
        XCTAssertEqual(
            classify(
                "/Volumes/Dock SSD/Obsidian/Second Brain",
                existing: ["/Volumes/Dock SSD/Obsidian/Second Brain", "/Volumes/Dock SSD"],
                volumeRoots: ["/Volumes/Dock SSD"]
            ),
            .available
        )
    }

    // MARK: - Folder missing (create as today)

    func testMissingFolderOnBootVolumeIsFolderMissing() {
        XCTAssertEqual(
            classify("/Users/me/Documents/Rapture Notes", existing: []),
            .folderMissing
        )
    }

    func testMissingSubfolderOnMountedVolumeIsFolderMissing() {
        XCTAssertEqual(
            classify(
                "/Volumes/Dock SSD/Obsidian/Second Brain",
                existing: ["/Volumes/Dock SSD"],
                volumeRoots: ["/Volumes/Dock SSD"]
            ),
            .folderMissing
        )
    }

    // MARK: - Volume absent (queue, never create)

    func testUnmountedVolumeIsVolumeAbsent() {
        XCTAssertEqual(
            classify("/Volumes/Dock SSD/Obsidian/Second Brain", existing: []),
            .volumeAbsent
        )
    }

    func testShadowFolderAtMountRootIsVolumeAbsent() {
        // /Volumes/<name> exists but is a plain directory on the boot volume
        // (a leftover shadow folder), not a real mount point.
        XCTAssertEqual(
            classify(
                "/Volumes/Dock SSD/Obsidian/Second Brain",
                existing: ["/Volumes/Dock SSD"],
                volumeRoots: []
            ),
            .volumeAbsent
        )
    }

    func testDestinationAtVolumeRootAbsentIsVolumeAbsent() {
        XCTAssertEqual(
            classify("/Volumes/RaptureTestVol", existing: []),
            .volumeAbsent
        )
    }

    func testDestinationAtVolumeRootMountedIsAvailable() {
        XCTAssertEqual(
            classify(
                "/Volumes/RaptureTestVol",
                existing: ["/Volumes/RaptureTestVol"],
                volumeRoots: ["/Volumes/RaptureTestVol"]
            ),
            .available
        )
    }

    // MARK: - Live probes sanity (no external drive required)

    func testDefaultProbesClassifyBootVolumePaths() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DestinationGuardTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let guardInstance = DestinationGuard()
        XCTAssertEqual(guardInstance.check(temp), .folderMissing)

        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        XCTAssertEqual(guardInstance.check(temp), .available)
    }

    func testDefaultProbesClassifyNonexistentVolumeAsAbsent() {
        let phantom = URL(fileURLWithPath: "/Volumes/RaptureGuardTest-\(UUID().uuidString)/Notes")
        XCTAssertEqual(DestinationGuard().check(phantom), .volumeAbsent)
    }
}
