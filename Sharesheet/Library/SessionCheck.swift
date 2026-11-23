import Foundation
import SharesheetCore
import UserNotifications

/// Checks the stored account sessions and reports an expired one once, without touching it.
@MainActor
struct SessionCheck {
    struct Probe {
        let id: String
        let name: String
        let validate: @Sendable () async -> SessionStatus
    }

    var probes: [Probe]
    var defaults: UserDefaults = .standard
    var deliver: (_ id: String, _ name: String) async -> Bool = SessionCheck.deliverNotification

    /// Reports each expired probe once until a later check is valid or the session is removed.
    func run() async {
        for probe in probes {
            let status = await probe.validate()
            let key = Self.notificationKey(for: probe.id)
            switch status {
            case .expired:
                guard !defaults.bool(forKey: key) else { continue }
                if await deliver(probe.id, probe.name) { defaults.set(true, forKey: key) }
            case .valid, .noSession:
                defaults.removeObject(forKey: key)
            case .unknown:
                continue
            }
        }
    }

    /// Asks once, when a session exists and the choice is still open.
    static func requestAuthorizationIfNeeded() async {
        guard InstagramSessionStore.shared.load() != nil
            || WebSessionStore.x.load() != nil
            || WebSessionStore.facebook.load() != nil
        else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func notificationKey(for id: String) -> String {
        "sessionCheck.notified.\(id)"
    }

    private static func deliverNotification(id: String, name: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "\(name) session expired"
        content.body = "Private posts need a new sign-in. Open Settings → Accounts."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "session-expired.\(id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}
