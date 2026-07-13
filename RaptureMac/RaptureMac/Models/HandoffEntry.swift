import Foundation

/// One Reminders/Calendar item the handoff engine created, keyed by content
/// fingerprint (kind + normalized title + due/start key) so a re-dictated
/// duplicate within the ledger window never double-creates. Persisted in
/// `PersistedState.handoffRecords`; see `HandoffLedger`.
struct HandoffEntry: Codable, Sendable, Equatable {
    var fingerprint: String
    var createdAt: Date
}
