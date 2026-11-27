import AppKit
import Foundation
import UserNotifications

final class DelegateHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DelegateHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.identifier
        let identifier = response.actionIdentifier
        let deviceId = response.notification.request.content.userInfo["deviceId"] as? String

        Task { @MainActor in
            // Clipboard-arrival banners aren't phone notifications — tapping
            // the body enables sync and copies the held clip. They must never
            // fall through to the phone-notification actions below.
            if key.hasPrefix("notifmirror.clip") {
                if identifier == UNNotificationDefaultActionIdentifier {
                    ClipboardSync.shared.acceptPendingClip()
                }
                completionHandler()
                return
            }
            if identifier == UNNotificationDismissActionIdentifier {
                WsServer.shared.sendDismiss(key: key, to: deviceId)
            } else if identifier == UNNotificationDefaultActionIdentifier {
                WsServer.shared.sendAction(key: key, actionId: "__open__", text: nil, to: deviceId)
                MainWindowSelection.shared.pending = .notifications
                MainWindowSelection.shared.pendingNotificationKey = key
                AppState.shared.openMainWindowRequest = UUID()
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let actionId = parseActionId(from: identifier, key: key)
                if let textResponse = response as? UNTextInputNotificationResponse {
                    WsServer.shared.sendAction(key: key, actionId: actionId, text: textResponse.userText, to: deviceId)
                } else {
                    WsServer.shared.sendAction(key: key, actionId: actionId, text: nil, to: deviceId)
                }
            }
            completionHandler()
        }
    }

    /// Action identifiers are encoded as "<key>#<actionId>"; recover the suffix.
    private func parseActionId(from identifier: String, key: String) -> String {
        let prefix = "\(key)#"
        if identifier.hasPrefix(prefix) {
            return String(identifier.dropFirst(prefix.count))
        }
        return identifier
    }
}
