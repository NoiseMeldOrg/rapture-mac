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
/// Match key is `(normalized self-handle, normalized text, attachment count)`
/// plus the send time: a message is a replay only when it was sent within
/// `replayWindow` of the capture it repeats. We use the same
/// `EchoGuard.normalize` so the matching rules stay aligned with what already
/// battle-tested the smart-quote / ZWJ / whitespace edge cases. TTL is months,
/// not seconds, because iCloud replays have arrived more than ten days after
/// the original.
///
/// Why the send time is part of the key: without it, the guard dropped every
/// note that had the same words as a note from the last 90 days, with no file
/// and no reply (2026-11-17: "Test" sent one day after "Test"). A replay keeps
/// the send time of the original. The June 2026 replays were 1 to 2 s off, and the
/// 2026-09-22 note that iCloud delivered again on 2026-10-02 had the same
/// `captured` second as the first copy. A note that the author sends again
/// later has a new send time.
@MainActor
final class ContentDedupCache {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "ContentDedupCache")

    /// Ninety days, matching `RelayFiledLedger.ttl`. The first replays we saw
    /// spanned ~30 hours, so this was seven days — until iCloud re-delivered a
    /// 2026-09-22 note on 2026-10-02 (10.5 days later, fresh GUIDs) and it filed
    /// again as a `-1` duplicate. Storage cost is trivial even at the cap.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// How far apart two send times may be and still be the same message.
    /// Observed replay offsets are 0 to 2 s. One minute leaves room for device
    /// clock differences. The cost of the margin is small: the same words sent
    /// twice inside one minute file once, and those words are already saved.
    nonisolated static let replayWindow: TimeInterval = 60

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

    func track(handle: String, text: String, attachmentCount: Int, sentAt: Date) {
        let now = clock()
        stateStore.update { state in
            state.recentCaptureHashes = Self.appendEntry(
                into: state.recentCaptureHashes,
                handle: handle,
                text: text,
                attachmentCount: attachmentCount,
                sentAt: sentAt,
                now: now
            )
        }
    }

    func contains(handle: String, text: String, attachmentCount: Int, sentAt: Date) -> Bool {
        let now = clock()
        return Self.matches(
            entries: stateStore.state.recentCaptureHashes,
            handle: handle,
            text: text,
            attachmentCount: attachmentCount,
            sentAt: sentAt,
            now: now
        )
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [CaptureHashEntry],
        handle: String,
        text: String,
        attachmentCount: Int,
        sentAt: Date,
        now: Date
    ) -> [CaptureHashEntry] {
        var kept = entries.filter { $0.expiresAt > now }
        let handleNorm = SelfHandleResolver.normalize(handle)
        let textNorm = EchoGuard.normalize(text)
        // If an entry for this same message already exists (defensive: the
        // caller normally checks `contains` first), refresh it rather than
        // appending a dup. An entry with the same words and another send time is another
        // note: it stays, so a late replay of that note is still caught.
        kept.removeAll { entry in
            entry.handleNormalized == handleNorm
                && entry.normalizedText == textNorm
                && entry.attachmentCount == attachmentCount
                && isReplay(of: entry, sentAt: sentAt)
        }
        kept.append(CaptureHashEntry(
            handleNormalized: handleNorm,
            normalizedText: textNorm,
            attachmentCount: attachmentCount,
            expiresAt: now.addingTimeInterval(ttl),
            sentAt: sentAt
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
        sentAt: Date,
        now: Date
    ) -> Bool {
        let handleNorm = SelfHandleResolver.normalize(handle)
        let textNorm = EchoGuard.normalize(text)
        for entry in entries {
            if entry.expiresAt <= now { continue }
            if entry.handleNormalized == handleNorm
                && entry.normalizedText == textNorm
                && entry.attachmentCount == attachmentCount
                && isReplay(of: entry, sentAt: sentAt) {
                return true
            }
        }
        return false
    }

    /// True when a message sent at `sentAt` is the message that `entry`
    /// records, delivered again. The caller has already matched the handle,
    /// the words, and the attachment count.
    nonisolated static func isReplay(of entry: CaptureHashEntry, sentAt: Date) -> Bool {
        if let original = entry.sentAt {
            return abs(sentAt.timeIntervalSince(original)) <= replayWindow
        }
        // An entry written before send times were stored. It holds only the
        // time of its capture (`expiresAt - ttl`; every such entry that is
        // still alive was written with the 90-day TTL). A replay carries the
        // send time of the original, and that is never after the capture. A
        // new note is sent after it. The last of these entries expires 90 days
        // after the update that added `sentAt`.
        let capturedAt = entry.expiresAt.addingTimeInterval(-ttl)
        return sentAt <= capturedAt.addingTimeInterval(replayWindow)
    }
}
