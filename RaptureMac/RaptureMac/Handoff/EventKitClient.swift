import Foundation

/// The two handoff destinations. Reminders and Calendars are separate TCC
/// grants on macOS 14+, so everything is kind-parameterized.
enum HandoffKind: String, Sendable, CaseIterable {
    case reminder
    case event

    var displayName: String {
        switch self {
        case .reminder: return "Reminders"
        case .event: return "Calendar"
        }
    }
}

enum HandoffAuthStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

/// A pickable Reminders list or calendar. `id` is EventKit's `calendarIdentifier`.
struct HandoffTarget: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

/// The EventKit seam. Production is `SystemEventKitClient` (the only file that
/// imports EventKit); tests inject a fake so the suite runs with no TCC grants
/// and no `EKEventStore` ever instantiated. The filing path only ever calls
/// `authorizationStatus`/create — `requestAccess` is driven exclusively by the
/// Settings toggle flow.
@MainActor
protocol EventKitClient: AnyObject {
    func authorizationStatus(for kind: HandoffKind) -> HandoffAuthStatus
    func requestAccess(for kind: HandoffKind) async -> Bool
    /// Writable Reminders lists / calendars for the Settings pickers.
    func targets(for kind: HandoffKind) -> [HandoffTarget]
    /// `due` nil = dateless reminder; date-only components = all-day due.
    /// `listID`/`calendarID` nil or stale = the system default target.
    func createReminder(title: String, due: DateComponents?, notes: String, listID: String?) throws
    func createEvent(title: String, start: Date, end: Date, notes: String, calendarID: String?) throws
}
