import Foundation
import UserNotifications

enum NotificationService {
    static let delegate = Delegate()

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }

    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// "You're invited" notifications for newly found events.
    @MainActor
    static func announce(newSuggestions: [SuggestedEvent], autoAdded: [SuggestedEvent]) async {
        let all = newSuggestions + autoAdded
        guard !all.isEmpty else { return }

        if all.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "\(all.count) new events for you"
            content.body = Set(all.map(\.departmentName)).sorted().joined(separator: ", ")
            content.sound = .default
            await post(content, id: "digest-\(Date().timeIntervalSince1970)")
            return
        }

        for suggestion in all {
            let content = UNMutableNotificationContent()
            let wasAutoAdded = autoAdded.contains { $0 === suggestion }
            content.title = wasAutoAdded ? "Added as maybe: \(suggestion.title)" : "You're invited: \(suggestion.title)"
            var body = "\(suggestion.departmentName) · " +
                suggestion.startDate.formatted(.dateTime.weekday().month().day().hour().minute())
            if suggestion.registrationURL != nil { body += "\nRegistration required — open to sign up." }
            content.body = body
            content.sound = .default
            await post(content, id: suggestion.externalId)
        }
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) async {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
