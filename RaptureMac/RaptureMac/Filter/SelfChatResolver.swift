import Foundation
import GRDB
import OSLog

@MainActor
final class SelfChatResolver {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SelfChatResolver")
    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    nonisolated static let dmChatStyle = 45

    private let dbPool: DatabasePool
    private let handlesProvider: @MainActor () -> Set<String>
    private(set) var currentGuid: String?
    private var refreshTask: Task<Void, Never>?

    init(dbPool: DatabasePool, handlesProvider: @escaping @MainActor () -> Set<String>) {
        self.dbPool = dbPool
        self.handlesProvider = handlesProvider
    }

    func start() async {
        await refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func currentSelfChatGuid() -> String? { currentGuid }

    private func refresh() async {
        let handles = handlesProvider()
        guard !handles.isEmpty else {
            Self.log.debug("Skipping refresh: no self handles yet")
            return
        }
        do {
            let guid = try await Self.fetchSelfChatGuid(in: dbPool, handles: handles)
            currentGuid = guid
            if let guid {
                Self.log.info("Self-chat resolved: \(guid, privacy: .public)")
            } else {
                Self.log.debug("Self-chat query returned no rows")
            }
        } catch {
            Self.log.error("Self-chat refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func fetchSelfChatGuid(in dbPool: DatabasePool, handles: Set<String>) async throws -> String? {
        let handleList = Array(handles)
        guard !handleList.isEmpty else { return nil }
        return try await dbPool.read { db in
            let placeholders = Array(repeating: "?", count: handleList.count).joined(separator: ",")
            let sql = """
                SELECT c.guid
                FROM chat c
                JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE c.style = \(dmChatStyle) AND LOWER(h.id) IN (\(placeholders))
                LIMIT 1
            """
            let args: [DatabaseValueConvertible] = handleList.map { $0 as DatabaseValueConvertible }
            return try String.fetchOne(db, sql: sql, arguments: StatementArguments(args))
        }
    }
}
