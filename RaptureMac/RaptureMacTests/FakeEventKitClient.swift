import Foundation
@testable import Rapture

/// Scriptable EventKit fake: records every call, never touches EventKit, so
/// the suite runs with no TCC grants. Injected wherever `EventKitClient` is
/// consumed (HandoffManager, AppState).
@MainActor
final class FakeEventKitClient: EventKitClient {
    struct CreatedReminder: Equatable {
        var title: String
        var due: DateComponents?
        var notes: String
        var listID: String?
    }

    struct CreatedEvent: Equatable {
        var title: String
        var start: Date
        var end: Date
        var notes: String
        var calendarID: String?
    }

    struct CreateFailure: Error, LocalizedError {
        var errorDescription: String? { "fake create failure" }
    }

    var statuses: [HandoffKind: HandoffAuthStatus] = [.reminder: .authorized, .event: .authorized]
    var requestResult = true
    var fakeTargets: [HandoffKind: [HandoffTarget]] = [:]
    var failCreates = false

    private(set) var statusQueries: [HandoffKind] = []
    private(set) var accessRequests: [HandoffKind] = []
    private(set) var createdReminders: [CreatedReminder] = []
    private(set) var createdEvents: [CreatedEvent] = []

    func authorizationStatus(for kind: HandoffKind) -> HandoffAuthStatus {
        statusQueries.append(kind)
        return statuses[kind] ?? .notDetermined
    }

    func requestAccess(for kind: HandoffKind) async -> Bool {
        accessRequests.append(kind)
        if requestResult {
            statuses[kind] = .authorized
        } else {
            statuses[kind] = .denied
        }
        return requestResult
    }

    func targets(for kind: HandoffKind) -> [HandoffTarget] {
        fakeTargets[kind] ?? []
    }

    func createReminder(title: String, due: DateComponents?, notes: String, listID: String?) throws {
        if failCreates { throw CreateFailure() }
        createdReminders.append(CreatedReminder(title: title, due: due, notes: notes, listID: listID))
    }

    func createEvent(title: String, start: Date, end: Date, notes: String, calendarID: String?) throws {
        if failCreates { throw CreateFailure() }
        createdEvents.append(CreatedEvent(title: title, start: start, end: end, notes: notes, calendarID: calendarID))
    }
}
