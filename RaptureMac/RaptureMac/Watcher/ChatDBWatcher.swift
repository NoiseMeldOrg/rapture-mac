import Foundation
import GRDB
import OSLog

@MainActor
final class ChatDBWatcher {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "ChatDBWatcher")

    private let dbPool: DatabasePool
    private var pollTask: Task<Void, Never>?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func events(watermarkProvider: @escaping @Sendable () async -> Int64) -> AsyncStream<MessageEvent> {
        let (stream, continuation) = AsyncStream<MessageEvent>.makeStream(bufferingPolicy: .unbounded)
        let pool = dbPool
        pollTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let watermark = await watermarkProvider()
                do {
                    let events = try await pool.read { db in
                        try Self.fetchEvents(db: db, watermark: watermark)
                    }
                    for event in events {
                        continuation.yield(event)
                    }
                } catch {
                    Self.log.error("Poll failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated static func maxRowid(in dbPool: DatabasePool) async throws -> Int64 {
        try await dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
    }

    nonisolated static func fetchEvents(db: Database, watermark: Int64) throws -> [MessageEvent] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.ROWID AS rowid, m.guid, m.text, m.attributedBody, m.date,
                   m.is_from_me, m.cache_has_attachments, m.service,
                   h.id AS handle_id, c.guid AS chat_guid, c.style AS chat_style
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ?
            ORDER BY m.ROWID ASC
        """, arguments: [watermark])

        return try rows.map { row in
            let rowid: Int64 = row["rowid"]
            let cacheHasAttachments = (row["cache_has_attachments"] as Int?) ?? 0 != 0
            let attachments = cacheHasAttachments
                ? try fetchAttachments(db: db, messageRowid: rowid)
                : []
            return MessageEvent(
                rowid: rowid,
                guid: row["guid"] ?? "",
                text: row["text"],
                attributedBody: row["attributedBody"],
                dateAppleNs: row["date"] ?? 0,
                isFromMe: ((row["is_from_me"] as Int?) ?? 0) != 0,
                cacheHasAttachments: cacheHasAttachments,
                service: row["service"] ?? "",
                handleId: row["handle_id"],
                chatGuid: row["chat_guid"],
                chatStyle: row["chat_style"],
                attachments: attachments
            )
        }
    }

    nonisolated static func fetchAttachments(db: Database, messageRowid: Int64) throws -> [AttachmentRef] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.filename, a.mime_type, a.transfer_name
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            WHERE maj.message_id = ?
        """, arguments: [messageRowid])
        return rows.compactMap { row -> AttachmentRef? in
            guard let raw: String = row["filename"] else { return nil }
            return AttachmentRef(
                sourcePath: expandTilde(raw),
                mimeType: row["mime_type"],
                transferName: row["transfer_name"]
            )
        }
    }

    nonisolated static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst(1)
    }
}
