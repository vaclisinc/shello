import Foundation
import HerdrKit
import UIKit
import UserNotifications

/// Local notifications and haptics for agent state changes.
@MainActor
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(_ alert: AgentAlert, host: HostProfile, sessionVisible: Bool) {
        let appActive = UIApplication.shared.applicationState == .active
        if appActive && sessionVisible {
            // The user is looking at this host; a tap on the wrist is enough.
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(alert.kind == .needsInput ? .warning : .success)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = host.displayName
        content.body = alert.agent.subtitle ?? alert.agent.kindLabel
        content.sound = .default
        content.threadIdentifier = host.id.uuidString
        content.userInfo = ["host": host.id.uuidString, "pane": alert.agent.paneId]
        let request = UNNotificationRequest(
            identifier: "\(host.id.uuidString)-\(alert.agent.terminalId)-\(alert.kind.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Where a tapped notification should take the user.
struct NotificationRoute: Equatable {
    var host: UUID
    var pane: String?
}

/// Shows notifications while the app is in the foreground too, and routes taps.
final class NotificationDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    @MainActor @Published var route: NotificationRoute?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let pane = info["pane"] as? String
        await MainActor.run { route = NotificationRoute(host: host, pane: pane) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
