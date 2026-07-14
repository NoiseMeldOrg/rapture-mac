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
/// flush, hand-drop/backlog triage). The AI tier (M4) plugs in via the `ai`
/// parameter: when the capture's AI result carries validated handoff
/// candidates, they replace the deterministic detector's output for that
/// capture — everything downstream (toggles, auth gating, past-skip, ledger
/// dedup, notes contract, reply suffix) is shared and unchanged.
@MainActor
protocol HandoffProcessing: AnyObject {
    func process(text: String, capturedAt: Date, ai: AITriageOutput?) async -> HandoffOutcome
}

extension HandoffProcessing {
    /// Deterministic-only convenience; pre-M4 call sites keep compiling.
    func process(text: String, capturedAt: Date) async -> HandoffOutcome {
        await process(text: text, capturedAt: capturedAt, ai: nil)
    }
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

    func process(text: String, capturedAt: Date, ai: AITriageOutput?) async -> HandoffOutcome {
        let settings = appState.settings.settings
        // Both toggles off = zero cost, zero EventKit contact — the "filing
        // untouched" guarantee.
        guard settings.remindersHandoffEnabled || settings.calendarHandoffEnabled else {
            return .none
        }

        let zone = timeZoneProvider()
        let detected = Self.candidates(text: text, capturedAt: capturedAt, timeZone: zone, ai: ai)
        guard !detected.isEmpty else { return .none }

        var outcome = HandoffOutcome()
        for item in detected {
            switch item.candidate {
            case .reminder(let title, let due):
                guard settings.remindersHandoffEnabled, authorized(.reminder) else { continue }
                let dateKey = HandoffLedger.dateKey(for: due, timeZone: zone)
                let fingerprints = Self.fingerprints(kind: .reminder, title: title, clause: item.clause, dateKey: dateKey)
                guard !fingerprints.contains(where: { ledger.contains(fingerprint: $0) }) else {
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
                    fingerprints.forEach { ledger.record(fingerprint: $0) }
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
                let dateKey = HandoffLedger.dateKey(forEventStart: start)
                let fingerprints = Self.fingerprints(kind: .event, title: title, clause: item.clause, dateKey: dateKey)
                guard !fingerprints.contains(where: { ledger.contains(fingerprint: $0) }) else {
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
                    fingerprints.forEach { ledger.record(fingerprint: $0) }
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

    /// Which detector runs (pure, table-tested):
    /// - No AI result (off/failed) → deterministic detector.
    /// - AI result whose handoff block was entirely discarded by validation
    ///   (`handoffsInvalidated`) → deterministic detector — a hallucinating
    ///   model must not silently disable the M3 behavior the user trusts.
    /// - Otherwise the AI candidates replace the detector's output, including
    ///   the valid "AI confidently found none" empty list (superset assumption).
    nonisolated static func candidates(
        text: String,
        capturedAt: Date,
        timeZone: TimeZone,
        ai: AITriageOutput?
    ) -> [HandoffDetector.Detected] {
        guard let ai, !ai.handoffsInvalidated else {
            return HandoffDetector.detectDetailed(text, capturedAt: capturedAt, timeZone: timeZone)
        }
        return ai.handoffs
    }

    /// Both dedup fingerprints for one creation: title-based (M3, stable for
    /// mechanical titles) and clause-based (M4, stable across AI title drift).
    /// Checked with OR, recorded together — so the same utterance never
    /// double-creates whichever tier detected it first.
    nonisolated static func fingerprints(
        kind: HandoffKind,
        title: String,
        clause: String,
        dateKey: String
    ) -> [String] {
        var result = [HandoffLedger.fingerprint(kind: kind, title: title, dateKey: dateKey)]
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(HandoffLedger.clauseFingerprint(kind: kind, clause: trimmed, dateKey: dateKey))
        }
        return result
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
