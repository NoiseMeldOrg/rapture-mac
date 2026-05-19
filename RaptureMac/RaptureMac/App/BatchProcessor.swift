import Foundation
import OSLog

/// Per-batch decision contract. The integer counts roll up to the caller for the optional catch-up summary.
struct BatchOutcome: Equatable {
    var successCount: Int
    var failureCount: Int
    var droppedCount: Int
    var isCatchup: Bool
}

protocol FileWriting: Sendable {
    func write(_ captured: CapturedMessage, to folder: URL) async -> WriteResult
}

extension FileWriter: FileWriting {}

/// Encapsulates per-batch orchestration: filter → echo check → write → reply.
///
/// First non-empty batch with `count > 3` is flagged as catchup; subsequent batches are live.
/// Extracted from Pipeline so the catch-up decision logic can be unit-tested without chat.db.
@MainActor
final class BatchProcessor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "BatchProcessor")
    nonisolated static let catchupThreshold = 3

    /// Pure helper for the catch-up decision. Unit-testable in isolation.
    nonisolated static func isCatchup(batchSize: Int, isFirstNonemptyBatchSeen: Bool) -> Bool {
        !isFirstNonemptyBatchSeen && batchSize > catchupThreshold
    }

    private let appState: AppState
    private let writer: FileWriting
    private let replier: Replier
    private let echoGuard: EchoGuard
    private let selfHandlesProvider: @MainActor () -> Set<String>
    private let selfChatGuidProvider: @MainActor () -> String?
    private let advanceWatermark: @MainActor (Int64) -> Void

    private var isFirstNonemptyBatchSeen = false

    init(
        appState: AppState,
        writer: FileWriting,
        replier: Replier,
        echoGuard: EchoGuard,
        selfHandlesProvider: @escaping @MainActor () -> Set<String>,
        selfChatGuidProvider: @escaping @MainActor () -> String?,
        advanceWatermark: @escaping @MainActor (Int64) -> Void
    ) {
        self.appState = appState
        self.writer = writer
        self.replier = replier
        self.echoGuard = echoGuard
        self.selfHandlesProvider = selfHandlesProvider
        self.selfChatGuidProvider = selfChatGuidProvider
        self.advanceWatermark = advanceWatermark
    }

    @discardableResult
    func process(batch: [MessageEvent]) async -> BatchOutcome {
        guard !batch.isEmpty else {
            return BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: false)
        }

        let isCatchup = !isFirstNonemptyBatchSeen && batch.count > Self.catchupThreshold
        isFirstNonemptyBatchSeen = true

        var outcome = BatchOutcome(successCount: 0, failureCount: 0, droppedCount: 0, isCatchup: isCatchup)
        let settings = appState.settings.settings
        let handles = selfHandlesProvider()

        for event in batch {
            let decision = MessageFilter.decide(
                event: event,
                selfHandles: handles,
                settings: settings,
                isCatchup: isCatchup
            )

            switch decision {
            case .drop(let reason):
                Self.log.debug("dropped rowid=\(event.rowid) reason=\(reason.rawValue, privacy: .public)")
                advanceWatermark(event.rowid)
                outcome.droppedCount += 1

            case .capture(let captured):
                if let chatGuid = captured.event.chatGuid,
                   echoGuard.consume(chatGuid: chatGuid, text: captured.decodedText) {
                    Self.log.debug("echo-suppressed rowid=\(event.rowid)")
                    advanceWatermark(event.rowid)
                    outcome.droppedCount += 1
                    continue
                }

                guard let folder = settings.outputFolder else {
                    appState.recordError("No output folder configured")
                    outcome.failureCount += 1
                    continue
                }

                let result = await writer.write(captured, to: folder)
                switch result.outcome {
                case .success(let url):
                    Self.log.info("wrote \(url.lastPathComponent, privacy: .public) (rowid=\(event.rowid))")
                    if !result.failedAttachments.isEmpty {
                        appState.recordError("Some attachments missing for \(url.lastPathComponent)")
                    } else if appState.lastError != nil {
                        appState.clearError()
                    }
                    advanceWatermark(event.rowid)
                    outcome.successCount += 1
                    await replier.replyForWrite(captured: captured, result: result, settings: settings)
                case .failure(let reason):
                    Self.log.error("write failed rowid=\(event.rowid): \(reason, privacy: .public)")
                    appState.recordError(reason)
                    outcome.failureCount += 1
                    await replier.replyForWrite(captured: captured, result: result, settings: settings)
                }
            }
        }

        if isCatchup {
            await replier.sendCatchupSummary(
                successCount: outcome.successCount,
                failureCount: outcome.failureCount,
                selfChatGuid: selfChatGuidProvider(),
                replyMode: settings.replyMode
            )
        }

        return outcome
    }
}
