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
    private lazy var contentDedupCache = ContentDedupCache(stateStore: appState.state)
    private lazy var triageLedger = TriageLedger(stateStore: appState.state)
    private lazy var spoolStore = SpoolStore(stateStore: appState.state)
    private lazy var spoolFiledLedger = SpoolFiledLedger(stateStore: appState.state)
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
    private var relayWatcher: RelayWatcher?
    private var relayProcessor: RelayProcessor?
    private var relayConsumerTask: Task<Void, Never>?
    private var triageWatcher: TriageWatcher?
    private var triageProcessor: TriageProcessor?
    private var triageConsumerTask: Task<Void, Never>?
    private var destinationMonitor: DestinationMonitor?
    private var started = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() async {
        // The unit-test bundle is hosted inside Rapture.app, so this runs during
        // `xcodebuild test`. Never start the live capture pipeline there: opening chat.db
        // raises a Full Disk Access TCC prompt that disrupts the headless test host
        // (xcodebuild logs "Restarting after unexpected exit"). See ProcessInfo.isRunningXCTests.
        guard !ProcessInfo.processInfo.isRunningXCTests else { return }
        guard !started else { return }
        started = true
        appState.settings.ensureDefaultOutputFolder()
        // Relay capture needs no chat.db, so it starts before (and independent of)
        // the FDA-gated iMessage path: relayed notes still file while FDA is pending.
        startRelay()
        // Triage likewise needs no FDA: the backlog drains and external arrivals
        // convert even while iMessage capture is still waiting on permission.
        startTriage()
        // Destination availability + spool flush; independent of FDA like the two
        // above (a spool from a previous run must drain even before FDA lands).
        startDestinationMonitor()
        await attemptStart()
    }

    func stop() {
        fdaPollTask?.cancel()
        consumerTask?.cancel()
        relayConsumerTask?.cancel()
        triageConsumerTask?.cancel()
        watcher?.stop()
        relayWatcher?.stop()
        triageWatcher?.stop()
        destinationMonitor?.stop()
        resolver?.stop()
        selfChatResolver?.stop()
        fdaPollTask = nil
        consumerTask = nil
        relayConsumerTask = nil
        triageConsumerTask = nil
        watcher = nil
        relayWatcher = nil
        relayProcessor = nil
        triageWatcher = nil
        triageProcessor = nil
        destinationMonitor = nil
        resolver = nil
        selfChatResolver = nil
        batchProcessor = nil
        dbPool = nil
        started = false
    }

    private func startRelay() {
        let processor = RelayProcessor(
            appState: appState,
            filer: RelayFiler(),
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: triageLedger
        )
        relayProcessor = processor

        let relayWatcher = RelayWatcher(folder: RelayWatcher.defaultRelayFolder)
        self.relayWatcher = relayWatcher

        let appState = self.appState
        let stream = relayWatcher.batches(
            enabledProvider: {
                await MainActor.run { appState.settings.settings.relayEnabled }
            },
            onStatus: { status in
                await MainActor.run { appState.relayStatus = status }
            }
        )

        relayConsumerTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { break }
                await self.relayProcessor?.process(batch: batch)
            }
        }
    }

    private func startTriage() {
        let processor = TriageProcessor(appState: appState, ledger: triageLedger)
        triageProcessor = processor

        let triageWatcher = TriageWatcher()
        self.triageWatcher = triageWatcher

        let appState = self.appState
        let stream = triageWatcher.batches(
            folderProvider: {
                await MainActor.run { appState.settings.settings.outputFolder }
            },
            modeProvider: {
                await MainActor.run { appState.settings.settings.triageMode }
            },
            onStatus: { status in
                await MainActor.run {
                    // A poll-tick status must not clobber an in-flight drain display;
                    // only a mode flip to raw (.off) may interrupt it — the user needs
                    // to see that the engine stopped.
                    if case .triaging = appState.triageStatus, status != .off { return }
                    appState.triageStatus = status
                }
            }
        )

        triageConsumerTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { break }
                await self.triageProcessor?.process(batch: batch)
            }
        }
    }

    private func startDestinationMonitor() {
        let monitor = DestinationMonitor(
            appState: appState,
            spool: spoolStore,
            flusher: SpoolFlusher(),
            ledger: spoolFiledLedger
        )
        destinationMonitor = monitor
        monitor.start()
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
            contentDedupCache: contentDedupCache,
            spool: spoolStore,
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
