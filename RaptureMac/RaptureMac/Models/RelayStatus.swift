import Foundation

/// Transient status of the relay capture source, surfaced in Settings → General.
/// Filing errors are deliberately not represented here; they live on
/// `AppState.relayLastError` so a per-tick status post can never clobber one.
enum RelayStatus: Equatable, Sendable {
    /// The relay setting is off.
    case off
    /// Enabled, but the synced relay folder does not exist on this Mac yet.
    /// The folder appears after the first iPhone send; this is not an error.
    case waitingForFolder
    /// The relay folder exists and scans are running.
    case watching
    /// iCloud placeholders are present that have not finished downloading.
    case waitingForDownload(count: Int)
}
