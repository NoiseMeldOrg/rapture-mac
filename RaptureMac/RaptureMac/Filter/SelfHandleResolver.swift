import Foundation
import GRDB
import OSLog

@MainActor
final class SelfHandleResolver {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SelfHandleResolver")
    static let refreshInterval: TimeInterval = 60

    private let dbPool: DatabasePool
    private(set) var handles: Set<String> = []
    private var refreshTask: Task<Void, Never>?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func start() async {
        await refresh()
        let pool = dbPool
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled else { return }
                do {
                    let fresh = try await Self.fetchHandles(in: pool)
                    await self?.update(handles: fresh)
                } catch {
                    Self.log.error("Self-handle refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func isSelf(handle: String?) -> Bool {
        guard let handle else { return false }
        return handles.contains(Self.normalize(handle))
    }

    func currentHandlesSnapshot() -> Set<String> { handles }

    private func update(handles: Set<String>) {
        self.handles = handles
    }

    private func refresh() async {
        do {
            let fresh = try await Self.fetchHandles(in: dbPool)
            handles = fresh
        } catch {
            Self.log.error("Initial self-handle fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func fetchHandles(in dbPool: DatabasePool) async throws -> Set<String> {
        try await dbPool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT account
                FROM message
                WHERE is_from_me = 1 AND account IS NOT NULL AND account != ''
                LIMIT 50
            """)
            return Set(rows.map(normalize))
        }
    }

    nonisolated static func normalize(_ value: String) -> String {
        let stripped: Substring
        if value.count >= 2,
           let first = value.first, first.isLetter,
           value[value.index(after: value.startIndex)] == ":" {
            stripped = value.dropFirst(2)
        } else {
            stripped = Substring(value)
        }
        return stripped.lowercased()
    }
}
