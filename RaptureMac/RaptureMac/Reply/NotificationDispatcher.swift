import Foundation
import OSLog
@preconcurrency import UserNotifications

protocol NotificationDispatching: Sendable {
    func send(title: String, body: String) async
}

final class NotificationDispatcher: NotificationDispatching, @unchecked Sendable {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "NotificationDispatcher")

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func send(title: String, body: String) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            Self.log.error("Notification dispatch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        default:
            break
        }
    }
}
