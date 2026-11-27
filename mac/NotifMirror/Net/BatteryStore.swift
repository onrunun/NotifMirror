import Foundation
import UserNotifications

/// Receives battery snapshots per connected phone, stores them on `AppState`,
/// and surfaces an edge-triggered low-battery banner per device.
@MainActor
final class BatteryStore {
    static let shared = BatteryStore()

    private var deliveredLowDevices: Set<String> = []

    private init() {}

    func handleRemoteState(_ b: WireMessage.BatteryState, from deviceId: String, deviceName: String) {
        let snap = BatterySnapshot(
            level: b.level,
            charging: b.charging,
            status: b.status,
            plugged: b.plugged,
            temperatureC: b.temperatureC,
            voltageMv: b.voltageMv,
            low: b.low,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(b.updatedAt) / 1000.0)
        )
        AppState.shared.updateBattery(snap, for: deviceId)

        let nowLow = b.low || (b.level >= 0 && b.level <= 15 && !b.charging)
        if nowLow && !deliveredLowDevices.contains(deviceId) {
            deliveredLowDevices.insert(deviceId)
            postLowBatteryNotification(deviceId: deviceId, deviceName: deviceName, level: b.level)
        } else if !nowLow {
            deliveredLowDevices.remove(deviceId)
        }
    }

    func peerDisconnected(deviceId: String? = nil) {
        if let deviceId {
            AppState.shared.updateBattery(nil, for: deviceId)
            deliveredLowDevices.remove(deviceId)
        } else {
            deliveredLowDevices.removeAll()
        }
    }

    private func postLowBatteryNotification(deviceId: String, deviceName: String, level: Int) {
        if AppState.shared.isMirroringPaused { return }
        let content = UNMutableNotificationContent()
        content.title = deviceName
        content.body = level >= 0 ? "Battery at \(level) %." : "Battery is low."
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: "notifmirror.battery.low.\(deviceId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("low-battery notify failed: \(err)") }
        }
    }
}
