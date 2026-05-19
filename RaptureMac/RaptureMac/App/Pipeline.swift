import Foundation
import GRDB
import OSLog

@MainActor
final class Pipeline {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "Pipeline")
    nonisolated static let fdaRetryInterval: TimeInterval = 2

    private let appState: AppState
    private let writer = FileWriter()
    private let sender = AppleScriptSender()
    private let notifications = NotificationDispatcher()
    private lazy var echoGuard = EchoGuard(stateStore: appState.state)
    private lazy var replier = Replier(
        sender: sender,
        echoGuard: echoGuard,
        notifications: notifications,
        stateStore: appState.state,
        appState: appState
    )

    private var dbPool: DatabasePool?
    private var watcher: ChatDBWatcher?
    private var resolver: SelfHandleResolver?
    private var selfChatResolver: SelfChatResolver?
    private var batchProcessor: BatchProcessor?
    private var fdaPollTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var started = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() async {
        guard !started else { return }
        started = true
        appState.settings.ensureDefaultOutputFolder()
        await attemptStart()
    }

    func stop() {
        fdaPollTask?.cancel()
        consumerTask?.cancel()
        watcher?.stop()
        resolver?.stop()
        selfChatResolver?.stop()
        fdaPollTask = nil
        consumerTask = nil
        watcher = nil
        resolver = nil
        selfChatResolver = nil
        batchProcessor = nil
        dbPool = nil
        started = false
    }

    private func attemptStart() async {
        do {
            let pool = try ChatDB.open()
            try await Self.smokeTest(pool: pool)
            await beginCapture(with: pool)
        } catch {
            if ChatDB.looksLikePermissionError(error) {
                Self.log.warning("FDA not granted yet: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.error("Unexpected open failure: \(error.localizedDescription, privacy: .public)")
            }
            appState.permissionState = .fullDiskAccessRequired
            startFDAPolling()
        }
    }

    private func startFDAPolling() {
        fdaPollTask?.cancel()
        fdaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.fdaRetryInterval))
                guard let self, !Task.isCancelled else { return }
                do {
                    let pool = try ChatDB.open()
                    try await Self.smokeTest(pool: pool)
                    await self.beginCapture(with: pool)
                    return
                } catch {
                    if !ChatDB.looksLikePermissionError(error) {
                        Self.log.error("FDA retry hit non-permission error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private func beginCapture(with pool: DatabasePool) async {
        dbPool = pool
        appState.permissionState = .ok

        await seedWatermarkIfNeeded(pool: pool)

        let resolver = SelfHandleResolver(dbPool: pool)
        await resolver.start()
        self.resolver = resolver

        let selfChatResolver = SelfChatResolver(dbPool: pool) { [weak resolver] in
            resolver?.currentHandlesSnapshot() ?? []
        }
        await selfChatResolver.start()
        self.selfChatResolver = selfChatResolver

        let batchProcessor = BatchProcessor(
            appState: appState,
            writer: writer,
            replier: replier,
            echoGuard: echoGuard,
            selfHandlesProvider: { [weak resolver] in
                resolver?.currentHandlesSnapshot() ?? []
            },
            selfChatGuidProvider: { [weak selfChatResolver] in
                selfChatResolver?.currentSelfChatGuid()
            },
            advanceWatermark: { [weak self] rowid in
                self?.advanceWatermark(to: rowid)
            }
        )
        self.batchProcessor = batchProcessor

        let watcher = ChatDBWatcher(dbPool: pool)
        self.watcher = watcher

        let appState = self.appState
        let stream = watcher.events {
            await MainActor.run { appState.state.state.chatDbWatermark }
        }

        consumerTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { break }
                await self.batchProcessor?.process(batch: batch)
                _ = self
            }
        }
    }

    private func advanceWatermark(to rowid: Int64) {
        appState.state.update {
            if rowid > $0.chatDbWatermark {
                $0.chatDbWatermark = rowid
            }
        }
    }

    private func seedWatermarkIfNeeded(pool: DatabasePool) async {
        let current = appState.state.state.chatDbWatermark
        guard current == 0 else { return }
        do {
            let max = try await ChatDBWatcher.maxRowid(in: pool)
            appState.state.update { $0.chatDbWatermark = max }
            Self.log.info("seeded watermark to max ROWID = \(max)")
        } catch {
            Self.log.error("Watermark seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func smokeTest(pool: DatabasePool) async throws {
        _ = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
    }
}
