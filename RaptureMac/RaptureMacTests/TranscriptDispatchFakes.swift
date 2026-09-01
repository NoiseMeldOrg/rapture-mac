import Foundation
@testable import Rapture

/// Scriptable `TranscriptSessionLaunching` — records launches, never spawns a
/// real `claude`, and lets tests flip the running flag / failure detail.
@MainActor
final class FakeTranscriptSessionLauncher: TranscriptSessionLaunching {
    private(set) var launches: [(prompt: String, workingDirectory: URL)] = []
    private(set) var terminateCount = 0
    var throwOnLaunch: TranscriptSessionError?
    var running = false
    var failureDetail: String?

    func launch(prompt: String, workingDirectory: URL) async throws {
        if let error = throwOnLaunch { throw error }
        launches.append((prompt, workingDirectory))
        running = true
    }

    func isRunning() -> Bool { running }

    func terminate() {
        terminateCount += 1
        running = false
    }

    func lastFailureDetail() -> String? { failureDetail }
}

/// A recording `TranscriptDispatching` spy for the enrichment seam tests
/// (the `SpyLinkEnriching` shape).
@MainActor
final class SpyTranscriptDispatching: TranscriptDispatching {
    private(set) var calls: [(fingerprint: String, url: String, noteRelativePath: String)] = []

    func captureEnriched(fingerprint: String, url: String, noteRelativePath: String) {
        calls.append((fingerprint, url, noteRelativePath))
    }
}
