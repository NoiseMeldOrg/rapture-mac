import Foundation
@testable import Rapture

/// Scriptable `GitStateReading` — returns a canned `GitRepoState` or throws a
/// `GitReadError`, and records the repo roots it was asked about. Never spawns
/// `git`, so the hosted suite reads no real repo and opens no socket.
@MainActor
final class FakeGitStateReader: GitStateReading {
    enum Behavior {
        case state(GitRepoState)
        case failure(GitReadError)
    }

    var behavior: Behavior
    private(set) var readRoots: [URL] = []

    init(behavior: Behavior) { self.behavior = behavior }

    func readState(repoRoot: URL) async throws -> GitRepoState {
        readRoots.append(repoRoot)
        switch behavior {
        case .state(let state): return state
        case .failure(let error): throw error
        }
    }
}
