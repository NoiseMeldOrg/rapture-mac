import Foundation

/// Backup health of the notes folder's git repository — the result
/// `BackupHealthMonitor` computes and publishes on `AppState`. Derived live from
/// local git state, read-only; nothing here is persisted, so a saved "healthy"
/// flag can never mask a real problem.
enum BackupHealth: Equatable, Sendable {
    /// No check has completed yet (startup).
    case unknown
    /// The notes folder isn't inside a git repository — nothing to back up.
    case notARepo
    /// The destination volume is absent (or the repo couldn't be read), so git
    /// state can't be inspected right now. Not a failure.
    case cannotCheck
    /// The repo is current, or has only fresh work still inside the grace window.
    /// `lastCommit` drives the "Backed up · 2h ago" display; `pendingChanges` > 0
    /// means there's un-backed-up work that hasn't yet aged past the threshold.
    case backedUp(lastCommit: Date?, pendingChanges: Int)
    /// Uncommitted or unpushed work has sat longer than the grace threshold.
    /// `since` is when the oldest un-backed-up work first appeared.
    case atRisk(since: Date, uncommitted: Int, unpushed: Int)
}

/// Pure presentation of `BackupHealth` for the two surfaces. Separated from the
/// views (house "pure-helper" style) so the toggle behavior and wording are
/// unit-tested directly, with no SwiftUI host.
enum BackupHealthPresentation {
    /// The always-shown Settings status line (near the output folder). `nil` only
    /// before the first check completes (`.unknown`) — the caller hides the row.
    struct SettingsLine: Equatable {
        var text: String
        var isWarning: Bool
        var systemImage: String
    }

    static func settingsLine(_ health: BackupHealth, now: Date = Date()) -> SettingsLine? {
        switch health {
        case .unknown:
            return nil
        case .notARepo:
            return SettingsLine(
                text: "Destination isn't a git repository — nothing to back up.",
                isWarning: false,
                systemImage: "info.circle"
            )
        case .cannotCheck:
            return SettingsLine(
                text: "Backup status unavailable — the drive isn't connected.",
                isWarning: false,
                systemImage: "externaldrive.badge.questionmark"
            )
        case .backedUp(let lastCommit, let pending):
            let commitPhrase = lastCommit.map { "Backed up · last commit \(agoPhrase($0, now: now))" } ?? "Backed up."
            let text = pending > 0
                ? "\(commitPhrase) · \(pending) change\(pending == 1 ? "" : "s") not yet backed up"
                : commitPhrase
            return SettingsLine(text: text, isWarning: false, systemImage: "checkmark.circle")
        case .atRisk(let since, let uncommitted, let unpushed):
            return SettingsLine(
                text: "Not backed up in \(durationPhrase(since: since, now: now)) — \(riskDetail(uncommitted: uncommitted, unpushed: unpushed)).",
                isWarning: true,
                systemImage: "externaldrive.badge.exclamationmark"
            )
        }
    }

    /// The loud menu-bar caption. `nil` unless the repo is at risk **and** the
    /// user opted into warnings — this is the one place the toggle gates output.
    static func menuWarning(_ health: BackupHealth, enabled: Bool, now: Date = Date()) -> String? {
        guard enabled, case .atRisk(let since, _, _) = health else { return nil }
        return "⚠︎ Notes folder not backed up in \(durationPhrase(since: since, now: now))"
    }

    // MARK: - Pure phrasing helpers (deterministic; locale-independent)

    static func riskDetail(uncommitted: Int, unpushed: Int) -> String {
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s")") }
        if unpushed > 0 { parts.append("\(unpushed) unpushed commit\(unpushed == 1 ? "" : "s")") }
        return parts.isEmpty ? "work not backed up" : parts.joined(separator: ", ")
    }

    /// Coarse "how long unbacked" phrase for a warning (always ≥ threshold, so it
    /// resolves to days/hours in practice).
    static func durationPhrase(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let days = Int(seconds / 86_400)
        if days >= 1 { return "\(days) day\(days == 1 ? "" : "s")" }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let minutes = Int(seconds / 60)
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// "just now" / "5m ago" / "2h ago" / "3d ago" for the healthy last-commit line.
    static func agoPhrase(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3_600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(seconds / 86_400)
        return "\(days)d ago"
    }
}
