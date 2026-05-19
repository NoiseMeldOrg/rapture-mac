import Foundation
import GRDB
import OSLog

@MainActor
final class Pipeline {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "Pipeline")
    static let fdaRetryInterval: TimeInterval = 2

    private let appState: AppState
    private var dbPool: DatabasePool?
    private var watcher: ChatDBWatcher?
    private var resolver: SelfHandleResolver?
    private var writer = FileWriter()
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
        fdaPollTask = nil
        consumerTask = nil
        watcher = nil
        resolver = nil
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

        let watcher = ChatDBWatcher(dbPool: pool)
        self.watcher = watcher

        let stateStore = appState.state
        let stream = watcher.events { [weak stateStore] in
            await MainActor.run { stateStore?.state.chatDbWatermark ?? 0 }
        }

        consumerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event: event)
            }
        }
    }

    private func handle(event: MessageEvent) async {
        let settings = appState.settings.settings
        let handles = resolver?.currentHandlesSnapshot() ?? []
        let decision = MessageFilter.decide(event: event, selfHandles: handles, settings: settings)

        switch decision {
        case .drop(let reason):
            Self.log.debug("dropped rowid=\(event.rowid) reason=\(reason.rawValue, privacy: .public)")
            advanceWatermark(to: event.rowid)
        case .capture(let captured):
            guard let folder = settings.outputFolder else {
                appState.recordError("No output folder configured")
                return
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
                advanceWatermark(to: event.rowid)
            case .failure(let reason):
                Self.log.error("write failed rowid=\(event.rowid): \(reason, privacy: .public)")
                appState.recordError(reason)
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
