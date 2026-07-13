import Foundation
import OSLog

/// What the handoff run produced — only what the iMessage reply suffix needs.
/// Failures and suppressed duplicates surface via `AppState.handoffLastError`
/// and OSLog instead (relay/spool/backlog callers have no reply path anyway).
struct HandoffOutcome: Equatable, Sendable {
    var reminderCreated = false
    var eventCreated = false

    static let none = HandoffOutcome()
    var any: Bool { reminderCreated || eventCreated }
}

/// The single handoff entry point, called once per freshly-filed capture at
/// each of the four filing seams (live iMessage write, relay filing, spool
/// flush, hand-drop/backlog triage). M4's AI detection plugs in behind this
/// same protocol.
@MainActor
protocol HandoffProcessing: AnyObject {
    func process(text: String, capturedAt: Date) async -> HandoffOutcome
}

/// Orchestrates detection → gating → dedup → EventKit creation. Strictly
/// additive and best-effort: it runs only after the note durably filed, and
/// nothing here can fail the filing. The filing path never *requests* access —
/// it only checks status; the request lives in the Settings toggle flow.
@MainActor
final class HandoffManager: HandoffProcessing {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "HandoffManager")

    /// Stated appointments get a 1-hour block when no end is given (locked).
    nonisolated static let eventDuration: TimeInterval = 60 * 60

    private let appState: AppState
    private let client: any EventKitClient
    private let ledger: HandoffLedger
    private let clock: @Sendable () -> Date
    /// Read at each use, never captured at init — the system zone can change mid-run.
    private let timeZoneProvider: @Sendable () -> TimeZone
    /// One-shot per kind: a revoked grant reports once, not on every capture.
    private var reportedAuthFailure: Set<HandoffKind> = []

    init(
        appState: AppState,
        client: any EventKitClient,
        ledger: HandoffLedger,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.appState = appState
        self.client = client
        self.ledger = ledger
        self.clock = clock
        self.timeZoneProvider = timeZoneProvider
    }

    func process(text: String, capturedAt: Date) async -> HandoffOutcome {
        let settings = appState.settings.settings
        // Both toggles off = zero cost, zero EventKit contact — the "filing
        // untouched" guarantee.
        guard settings.remindersHandoffEnabled || settings.calendarHandoffEnabled else {
            return .none
        }

        let zone = timeZoneProvider()
        let candidates = HandoffDetector.detect(text, capturedAt: capturedAt, timeZone: zone)
        guard !candidates.isEmpty else { return .none }

        var outcome = HandoffOutcome()
        for candidate in candidates {
            switch candidate {
            case .reminder(let title, let due):
                guard settings.remindersHandoffEnabled, authorized(.reminder) else { continue }
                let dateKey = HandoffLedger.dateKey(for: due, timeZone: zone)
                let fingerprint = HandoffLedger.fingerprint(kind: .reminder, title: title, dateKey: dateKey)
                guard !ledger.contains(fingerprint: fingerprint) else {
                    Self.log.info("reminder suppressed (ledger dup): \(title, privacy: .private)")
                    continue
                }
                do {
                    try client.createReminder(
                        title: title,
                        due: dueComponents(for: due, zone: zone),
                        notes: notes(for: text, capturedAt: capturedAt),
                        listID: settings.remindersListID
                    )
                    ledger.record(fingerprint: fingerprint)
                    outcome.reminderCreated = true
                    noteSuccess(.reminder)
                    Self.log.info("reminder created: \(title, privacy: .private)")
                } catch {
                    reportError("Couldn't create reminder: \(error.localizedDescription)")
                }

            case .event(let title, let start):
                guard settings.calendarHandoffEnabled, authorized(.event) else { continue }
                // Past-dated appointments are skipped (a spool item can flush
                // after the appointment happened); past-due reminders still
                // create above — overdue is actionable, a past event is noise.
                guard start > clock() else {
                    Self.log.info("event skipped (start already passed): \(title, privacy: .private)")
                    continue
                }
                let fingerprint = HandoffLedger.fingerprint(
                    kind: .event,
                    title: title,
                    dateKey: HandoffLedger.dateKey(forEventStart: start)
                )
                guard !ledger.contains(fingerprint: fingerprint) else {
                    Self.log.info("event suppressed (ledger dup): \(title, privacy: .private)")
                    continue
                }
                do {
                    try client.createEvent(
                        title: title,
                        start: start,
                        end: start.addingTimeInterval(Self.eventDuration),
                        notes: notes(for: text, capturedAt: capturedAt),
                        calendarID: settings.calendarID
                    )
                    ledger.record(fingerprint: fingerprint)
                    outcome.eventCreated = true
                    noteSuccess(.event)
                    Self.log.info("event created: \(title, privacy: .private)")
                } catch {
                    reportError("Couldn't create event: \(error.localizedDescription)")
                }
            }
        }
        return outcome
    }

    // MARK: - Helpers

    /// Status check only — never a request. A toggle left on after the user
    /// revoked the grant in System Settings reports once and goes quiet.
    private func authorized(_ kind: HandoffKind) -> Bool {
        guard client.authorizationStatus(for: kind) == .authorized else {
            if !reportedAuthFailure.contains(kind) {
                reportedAuthFailure.insert(kind)
                reportError("\(kind.displayName) access is off — re-enable it in System Settings › Privacy & Security")
            }
            return false
        }
        return true
    }

    private func noteSuccess(_ kind: HandoffKind) {
        reportedAuthFailure.remove(kind)
        appState.handoffLastError = nil
    }

    private func reportError(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        appState.handoffLastError = message
    }

    /// The created item carries the full original dictation — nothing is lost
    /// if the mechanical title mangled a nuance.
    nonisolated static func composeNotes(text: String, capturedAt: Date) -> String {
        "\(text)\n\nCaptured via Rapture \(CaptureContract.iso8601(capturedAt))"
    }

    private func notes(for text: String, capturedAt: Date) -> String {
        Self.composeNotes(text: text, capturedAt: capturedAt)
    }

    /// Timed due → minute precision; date-only due → all-day components.
    nonisolated static func dueComponents(
        for resolved: HandoffDateParser.Resolved?,
        zone: TimeZone
    ) -> DateComponents? {
        guard let resolved else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if resolved.hasTime {
            return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved.date)
        }
        return calendar.dateComponents([.year, .month, .day], from: resolved.date)
    }

    private func dueComponents(for resolved: HandoffDateParser.Resolved?, zone: TimeZone) -> DateComponents? {
        Self.dueComponents(for: resolved, zone: zone)
    }
}
