import AppKit
import BackstageCore
import UserNotifications

/// A notification when an agent asks for the user, once per request.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((Int32) -> Void)?
    private var announced: Set<String> = []
    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func update(_ sessions: [Registry.SessionInfo]) {
        for session in sessions where session.status == .needsYou {
            let key = "\(session.pid):\(session.message ?? "")"
            guard !announced.contains(key) else { continue }
            announced.insert(key)
            post(title: "\(session.client) needs you", body: session.message ?? "Open Backstage to see what it needs.", pid: session.pid)
        }
    }

    private func post(title: String, body: String, pid: Int32) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["pid": Int(pid)]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pid = response.notification.request.content.userInfo["pid"] as? Int {
            DispatchQueue.main.async { self.onOpen?(Int32(pid)) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
