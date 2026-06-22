import Foundation

/// A minimal single-permit async mutex used to make capture writes and an output-folder
/// relocation mutually exclusive.
///
/// The whole capture pipeline is `@MainActor` and processes batches serially, but a
/// `FileWriter.write` can suspend (up to ~2s on attachment retry). During that suspension
/// the relocation's `await` could otherwise interleave and move files out from under an
/// in-flight write — and a batch captures its output-folder URL at the top, so switching
/// folders mid-batch would strand notes in the old folder. Wrapping the whole batch and
/// the whole move in `withLock` guarantees neither overlaps the other.
@MainActor
final class CaptureGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Run `body` with exclusive access, waiting if another holder is active.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        // Single-threaded on the main actor, so this loop only re-suspends when a prior
        // holder is still active when we resume.
        while locked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        locked = true
    }

    private func release() {
        locked = false
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }
}
