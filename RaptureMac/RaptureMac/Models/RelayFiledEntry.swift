import Foundation

/// One filed relay item, persisted in `state.json` so restarts and iCloud re-syncs
/// never file the same relay filename twice. Keyed by the relay file's
/// `lastPathComponent` (a re-send from the iPhone overwrites the same name, so the
/// name is the dedup identity). See `RelayFiledLedger`.
struct RelayFiledEntry: Codable, Sendable, Equatable {
    let relayFilename: String
    let filedAt: Date
}
