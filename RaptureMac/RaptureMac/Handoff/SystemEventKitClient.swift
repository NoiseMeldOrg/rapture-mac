import EventKit
import Foundation
import OSLog

/// Production `EventKitClient` — the only file in the target that imports
/// EventKit. The `EKEventStore` is created lazily inside methods (constructing
/// this class is inert, so `AppState` can hold it unconditionally), and every
/// method is front-guarded against XCTest: the test bundle is hosted in the
/// app, so the app's `@main` runs under `xcodebuild test` and must never be
/// able to trip a Reminders/Calendars TCC prompt — defense in depth on top of
/// "toggles default off" and "tests inject a fake".
@MainActor
final class SystemEventKitClient: EventKitClient {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SystemEventKitClient")

    enum ClientError: LocalizedError {
        case unavailableUnderTests
        case noTargetCalendar(HandoffKind)

        var errorDescription: String? {
            switch self {
            case .unavailableUnderTests:
                return "EventKit is unavailable in the test host"
            case .noTargetCalendar(let kind):
                return "No \(kind.displayName) list is available to receive the item"
            }
        }
    }

    private var store: EKEventStore?

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    private nonisolated static func entityType(for kind: HandoffKind) -> EKEntityType {
        switch kind {
        case .reminder: return .reminder
        case .event: return .event
        }
    }

    // MARK: - EventKitClient

    func authorizationStatus(for kind: HandoffKind) -> HandoffAuthStatus {
        guard !ProcessInfo.processInfo.isRunningXCTests else { return .denied }
        // Status is a static query — no store, no prompt.
        switch EKEventStore.authorizationStatus(for: Self.entityType(for: kind)) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .authorized
        default:
            // .writeOnly counts as denied: the pickers need to enumerate
            // lists, and the Settings flow requests full access only.
            return .denied
        }
    }

    func requestAccess(for kind: HandoffKind) async -> Bool {
        guard !ProcessInfo.processInfo.isRunningXCTests else { return false }
        do {
            switch kind {
            case .reminder:
                return try await eventStore().requestFullAccessToReminders()
            case .event:
                return try await eventStore().requestFullAccessToEvents()
            }
        } catch {
            Self.log.error("\(kind.rawValue) access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func targets(for kind: HandoffKind) -> [HandoffTarget] {
        guard !ProcessInfo.processInfo.isRunningXCTests else { return [] }
        return eventStore()
            .calendars(for: Self.entityType(for: kind))
            .filter(\.allowsContentModifications)
            .map { HandoffTarget(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func createReminder(title: String, due: DateComponents?, notes: String, listID: String?) throws {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw ClientError.unavailableUnderTests }
        let store = eventStore()
        guard let calendar = resolveCalendar(id: listID, in: store, fallback: store.defaultCalendarForNewReminders()) else {
            throw ClientError.noTargetCalendar(.reminder)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        reminder.dueDateComponents = due
        try store.save(reminder, commit: true)
    }

    func createEvent(title: String, start: Date, end: Date, notes: String, calendarID: String?) throws {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw ClientError.unavailableUnderTests }
        let store = eventStore()
        guard let calendar = resolveCalendar(id: calendarID, in: store, fallback: store.defaultCalendarForNewEvents) else {
            throw ClientError.noTargetCalendar(.event)
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
    }

    /// The stale/nil-target policy lives here, in one place: a stored ID that
    /// no longer resolves (deleted list, changed account) falls back to the
    /// system default rather than failing the handoff.
    private func resolveCalendar(id: String?, in store: EKEventStore, fallback: EKCalendar?) -> EKCalendar? {
        if let id, let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        return fallback
    }
}
