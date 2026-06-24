import Foundation
import UserNotifications

enum NotificationCenterService {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func notifyDownloadFinished(title: String, fileName: String?) {
        schedule(
            title: "Download finished",
            body: fileName ?? title,
            identifier: "download-finished-\(UUID().uuidString)"
        )
    }

    static func notifyDownloadFailed(title: String, message: String) {
        schedule(
            title: "Download failed",
            body: "\(title): \(message)",
            identifier: "download-failed-\(UUID().uuidString)"
        )
    }

    private static func schedule(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
