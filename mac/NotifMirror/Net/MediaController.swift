import Foundation

/// Holds the latest media snapshot per connected phone and routes playback
/// commands back to the phone that owns the currently displayed session.
@MainActor
final class MediaController {
    static let shared = MediaController()

    private init() {}

    func handleRemoteState(_ m: WireMessage.MediaState, from deviceId: String) {
        let snap = MediaSnapshot(
            pkg: m.pkg,
            app: m.app,
            title: m.title,
            artist: m.artist,
            album: m.album,
            artworkBase64: m.artwork,
            playing: m.playing,
            positionMs: m.positionMs,
            durationMs: m.durationMs,
            canPause: m.canPause,
            canSkipNext: m.canSkipNext,
            canSkipPrev: m.canSkipPrev,
            volume: m.volume,
            maxVolume: m.maxVolume,
            updatedAt: Date()
        )
        AppState.shared.updateMedia(snap, for: deviceId)
    }

    func send(cmd: String, value: Int? = nil, to explicitDeviceId: String? = nil) {
        guard Preferences.shared.mediaControlEnabled else { return }
        let target = explicitDeviceId ?? AppState.shared.mediaDevice?.id
        WsServer.shared.send(.mediaCmd(cmd: cmd, value: value), to: target)
    }

    func refresh(to explicitDeviceId: String? = nil) {
        let target = explicitDeviceId ?? AppState.shared.mediaDevice?.id
        WsServer.shared.send(.mediaCmd(cmd: "refresh", value: nil), to: target)
    }

    func peerDisconnected(deviceId: String? = nil) {
        if let deviceId {
            AppState.shared.updateMedia(.empty, for: deviceId)
        }
    }
}
