import Foundation
import OSLog

/// Content-hash dedup that survives across captures, batches, and app restarts.
///
/// Sibling to `EchoGuard` but solving a different problem: iCloud's cross-device
/// message sync re-delivers the same logical Siri-dictated note to chat.db hours
/// or days later, each time with a fresh `message.guid` (so the existing GUID
/// dedup in `BatchProcessor` doesn't catch it) and a timestamp offset by 1–2 s
/// (so the resulting filename differs and no overwrite collapse happens). The
/// daily 15:16 EDT cluster the user reported was caused by a scheduled wake
/// event triggering iMessage iCloud reconnect, which then dumped the queued
/// duplicates as "new" rows.
///
/// Match key is `(normalized self-handle, normalized text, attachment count)`.
/// We use the same `EchoGuard.normalize` so the matching rules stay aligned
/// with what already battle-tested the smart-quote / ZWJ / whitespace edge
/// cases. TTL is days, not seconds, because iCloud replays span the long-weekend
/// window we observed.
@MainActor
final class ContentDedupCache {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "ContentDedupCache")

    /// Seven days. Observed iCloud replays span ~30 hours; this gives margin
    /// for a long-weekend sleep plus late reconciliation. Storage cost is trivial
    /// even at the cap.
    nonisolated static let ttl: TimeInterval = 7 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. At ~200 captures/week this
    /// is the natural steady-state size; the cap is a safety net against pathological
    /// growth (e.g., an automated test rig hammering chat.db). FIFO eviction.
    nonisolated static let capacity = 500

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func track(handle: String, text: String, attachmentCount: Int) {
        let now = clock()
        stateStore.update { state in
            state.recentCaptureHashes = Self.appendEntry(
                into: state.recentCaptureHashes,
                handle: handle,
                text: text,
                attachmentCount: attachmentCount,
                now: now
            )
        }
    }

    func contains(handle: String, text: String, attachmentCount: Int) -> Bool {
        let now = clock()
        return Self.matches(
            entries: stateStore.state.recentCaptureHashes,
            handle: handle,
            text: text,
            attachmentCount: attachmentCount,
            now: now
        )
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [CaptureHashEntry],
        handle: String,
        text: String,
        attachmentCount: Int,
        now: Date
    ) -> [CaptureHashEntry] {
        var kept = entries.filter { $0.expiresAt > now }
        let handleNorm = SelfHandleResolver.normalize(handle)
        let textNorm = EchoGuard.normalize(text)
        // If an entry with the same key already exists (defensive — caller normally
        // checks `contains` first), refresh its expiry rather than appending a dup.
        kept.removeAll { entry in
            entry.handleNormalized == handleNorm
                && entry.normalizedText == textNorm
                && entry.attachmentCount == attachmentCount
        }
        kept.append(CaptureHashEntry(
            handleNormalized: handleNorm,
            normalizedText: textNorm,
            attachmentCount: attachmentCount,
            expiresAt: now.addingTimeInterval(ttl)
        ))
        // FIFO eviction to bound state.json size.
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func matches(
        entries: [CaptureHashEntry],
        handle: String,
        text: String,
        attachmentCount: Int,
        now: Date
    ) -> Bool {
        let handleNorm = SelfHandleResolver.normalize(handle)
        let textNorm = EchoGuard.normalize(text)
        for entry in entries {
            if entry.expiresAt <= now { continue }
            if entry.handleNormalized == handleNorm
                && entry.normalizedText == textNorm
                && entry.attachmentCount == attachmentCount {
                return true
            }
        }
        return false
    }
}
