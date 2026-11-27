import Foundation
import SwiftUI

struct ConnectedDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var host: String?
    var features: Set<String>
    var battery: BatterySnapshot?
    var media: MediaSnapshot
    let connectedAt: Date
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isServerListening: Bool = false
    @Published var listenerPort: UInt16 = 0
    @Published var devices: [ConnectedDevice] = []
    @Published var activeDeviceId: String? = nil
    @Published var scrcpyRunning: Bool = false
    @Published var notificationsMirroredCount: Int = 0
    @Published var lastError: String? = nil
    @Published var showPairingWindow: Bool = false
    @Published var openMainWindowRequest: UUID? = nil
    @Published var pairingRevision: Int = 0

    // Clipboard sync last-activity indicator + RAM-only session history (never written to disk).
    @Published var lastClipDirection: ClipDirection? = nil
    @Published var lastClipAt: Date? = nil
    @Published var clipHistory: [ClipHistoryItem] = []

    // Presentation / Pause Mirroring mode. When non-nil and in the future,
    // macOS banners are suppressed while incoming notifications are still
    // quietly logged to history.
    @Published var pausedUntil: Date? = nil
    private var pauseTimer: Timer?

    // File transfers (both direct handoffs and Phone Files pulls/pushes), keyed by xid.
    @Published var transfers: [String: TransferProgress] = [:]

    /// Set while an end-to-end notification test is in flight.
    @Published var pendingE2ETestReqId: String? = nil

    private init() {}

    // MARK: - Multi-device helpers & compatibility accessors

    var activeDevice: ConnectedDevice? {
        if let id = activeDeviceId, let found = devices.first(where: { $0.id == id }) {
            return found
        }
        return devices.first
    }

    var mediaDevice: ConnectedDevice? {
        if let active = activeDevice, active.media.hasSession {
            return active
        }
        if let playing = devices.first(where: { $0.media.hasSession && $0.media.playing }) {
            return playing
        }
        if let anySession = devices.first(where: { $0.media.hasSession }) {
            return anySession
        }
        return activeDevice
    }

    var isClientConnected: Bool { !devices.isEmpty }
    var pairedDeviceName: String? { activeDevice?.name }
    var peerHost: String? { activeDevice?.host }
    var peerFeatures: Set<String> { activeDevice?.features ?? [] }
    var battery: BatterySnapshot? { activeDevice?.battery }
    var media: MediaSnapshot { mediaDevice?.media ?? .empty }

    func device(id: String?) -> ConnectedDevice? {
        if let id, let found = devices.first(where: { $0.id == id }) {
            return found
        }
        return activeDevice
    }

    func upsertDevice(id: String, name: String, host: String?, features: Set<String>) {
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            devices[idx].name = name
            devices[idx].host = host
            devices[idx].features = features
        } else {
            devices.append(ConnectedDevice(
                id: id,
                name: name,
                host: host,
                features: features,
                battery: nil,
                media: .empty,
                connectedAt: Date()
            ))
        }
        if activeDeviceId == nil || !devices.contains(where: { $0.id == activeDeviceId }) {
            activeDeviceId = devices.first?.id
        }
        WsServer.shared.setDefaultTargetDevice(activeDeviceId)
    }

    func removeDevice(id: String) {
        devices.removeAll { $0.id == id }
        if activeDeviceId == id {
            activeDeviceId = devices.first?.id
        }
        WsServer.shared.setDefaultTargetDevice(activeDeviceId)
    }

    func removeAllDevices() {
        devices.removeAll()
        activeDeviceId = nil
        WsServer.shared.setDefaultTargetDevice(nil)
    }

    func selectDevice(_ id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        activeDeviceId = id
        WsServer.shared.setDefaultTargetDevice(id)
    }

    func updateBattery(_ snapshot: BatterySnapshot?, for deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].battery = snapshot
    }

    func updateMedia(_ snapshot: MediaSnapshot, for deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].media = snapshot
    }

    func incrementMirrored() { notificationsMirroredCount += 1 }

    // MARK: - Presentation / Pause Mirroring Mode

    var isMirroringPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    var pauseLabel: String? {
        guard let until = pausedUntil, until > Date() else { return nil }
        if until == .distantFuture { return "Paused until resumed" }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "Paused until \(fmt.string(from: until))"
    }

    func pauseMirroring(for duration: TimeInterval?) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        if let duration {
            let until = Date().addingTimeInterval(duration)
            pausedUntil = until
            pauseTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.resumeMirroring() }
            }
        } else {
            pausedUntil = .distantFuture
        }
    }

    func resumeMirroring() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntil = nil
    }

    // MARK: - RAM-only Clipboard History

    func recordClip(_ text: String, direction: ClipDirection, deviceName: String? = nil) {
        if let first = clipHistory.first, first.text == text, first.direction == direction {
            clipHistory[0] = ClipHistoryItem(
                id: first.id, text: text, direction: direction, deviceName: deviceName, at: Date()
            )
            return
        }
        clipHistory.insert(
            ClipHistoryItem(id: UUID(), text: text, direction: direction, deviceName: deviceName, at: Date()),
            at: 0
        )
        if clipHistory.count > 10 {
            clipHistory.removeLast(clipHistory.count - 10)
        }
    }

    func clearClipHistory() {
        clipHistory.removeAll()
    }
}

enum ClipDirection: String {
    case incoming, outgoing
}

struct ClipHistoryItem: Identifiable, Equatable {
    let id: UUID
    let text: String
    let direction: ClipDirection
    var deviceName: String? = nil
    let at: Date
}

struct MediaSnapshot: Equatable {
    var pkg: String?
    var app: String?
    var title: String?
    var artist: String?
    var album: String?
    var artworkBase64: String?
    var playing: Bool
    var positionMs: Int64
    var durationMs: Int64
    var canPause: Bool
    var canSkipNext: Bool
    var canSkipPrev: Bool
    var volume: Int
    var maxVolume: Int
    var updatedAt: Date

    static let empty = MediaSnapshot(
        pkg: nil, app: nil, title: nil, artist: nil, album: nil, artworkBase64: nil,
        playing: false, positionMs: 0, durationMs: 0,
        canPause: false, canSkipNext: false, canSkipPrev: false,
        volume: 0, maxVolume: 0,
        updatedAt: .distantPast
    )

    var hasSession: Bool { pkg != nil && (title != nil || artist != nil) }
}

struct BatterySnapshot: Equatable {
    var level: Int
    var charging: Bool
    var status: String
    var plugged: String
    var temperatureC: Double?
    var voltageMv: Int?
    var low: Bool
    var updatedAt: Date

    var hasLevel: Bool { level >= 0 }

    var sfSymbol: String {
        if !hasLevel { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch level {
        case ...10:  return "battery.0"
        case 11...30: return "battery.25"
        case 31...60: return "battery.50"
        case 61...85: return "battery.75"
        default:      return "battery.100"
        }
    }

    var tint: Color {
        if low || (hasLevel && level <= 15) { return .red }
        if hasLevel && level <= 25 { return .orange }
        if charging { return .green }
        return .secondary
    }
}

struct TransferProgress: Identifiable, Equatable {
    enum Direction { case incoming, outgoing }
    enum Source: Equatable { case direct, filesBrowse }
    enum Status: Equatable {
        case pending        // offer sent, waiting for accept
        case active
        case done
        case failed(String)
        case cancelled
    }

    let id: String           // xid
    let direction: Direction
    var source: Source = .direct
    var deviceId: String? = nil
    var deviceName: String? = nil
    var name: String
    var size: Int64
    var bytesTransferred: Int64
    var status: Status
    var destinationPath: String? = nil
    var sourceURL: URL? = nil
    var itemCount: Int = 1
    var startedAt: Date = Date()

    var isInFlight: Bool {
        switch status {
        case .pending, .active: return true
        default: return false
        }
    }
}
