import AppKit
import SwiftUI

struct OverviewPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = NotificationHistory.shared
    @ObservedObject private var prefs = Preferences.shared
    @State private var pendingVolume: Double? = nil
    @State private var manualClipText: String = ""
    @State private var clipSendFeedback: String? = nil
    @State private var copiedClipId: UUID? = nil

    var body: some View {
        PaneContainer("Overview", subtitle: subtitle) {
            ScrollView {
                VStack(spacing: 16) {
                    if state.isClientConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
        .onChange(of: state.media.volume) { _, _ in pendingVolume = nil }
    }

    private var subtitle: String {
        if state.isClientConnected {
            if let pause = state.pauseLabel {
                return "\(pause) — notifications still record to history."
            }
            return state.pairedDeviceName.map { "Streaming from \($0)." } ?? "Streaming from your phone."
        } else if state.isServerListening {
            return "Scan the code below from NotifMirror on your Android phone."
        } else {
            return "The local server isn't running. Try relaunching NotifMirror."
        }
    }

    // MARK: - Disconnected

    @ViewBuilder
    private var disconnectedContent: some View {
        if state.listenerPort == 0 {
            Card {
                ProgressView("Starting local server…")
                    .frame(maxWidth: .infinity).padding()
            }
        } else if let payload = Pairing.shared.payloadJSON(
            host: LocalAddress.currentLanIPv4(),
            port: Int(state.listenerPort)
        ) {
            Card {
                VStack(spacing: 14) {
                    QRCodeView(payload: payload)
                        .id(state.pairingRevision)
                        .frame(width: 220, height: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white)
                        )

                    Text("Open NotifMirror on your Android phone, tap **Pair**, and scan this code.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)

                    HStack(spacing: 16) {
                        Label(LocalAddress.currentLanIPv4(), systemImage: "network")
                        Label(String(state.listenerPort), systemImage: "number.circle")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)

                    HStack(spacing: 10) {
                        CopyPayloadButton(payload: payload)
                        RegenerateSecretButton(title: "Regenerate")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedContent: some View {
        statusRow

        if state.media.hasSession && prefs.mediaControlEnabled {
            nowPlayingCard
        }

        if state.peerFeatures.contains("clip") {
            clipboardHubCard
        }

        let activeTransfers = state.transfers.values
            .filter { $0.isInFlight }
            .sorted { $0.startedAt > $1.startedAt }
        if !activeTransfers.isEmpty {
            activeTransfersCard(items: activeTransfers)
        }

        recentNotificationsCard
    }

    private var statusRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(state.isMirroringPaused ? Color.orange : Color.green)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.pairedDeviceName ?? "Connected")
                            .font(.headline)
                        Text(state.pauseLabel ?? "Receiving notifications • \(history.entries.count) in history")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(state.isMirroringPaused ? .orange : .secondary)
                    }
                    Spacer()
                    if state.peerFeatures.contains("battery"), let b = state.battery, b.hasLevel {
                        HStack(spacing: 4) {
                            Image(systemName: b.sfSymbol).foregroundStyle(b.tint)
                            Text("\(b.level)%")
                                .font(.callout.weight(.medium).monospacedDigit())
                                .foregroundStyle(b.tint)
                        }
                        .padding(.trailing, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Phone battery \(b.level) percent\(b.charging ? ", charging" : "")")
                    }
                    PauseMirroringMenu(state: state)
                    Button {
                        MainWindowSelection.shared.showPairingSheet = true
                    } label: {
                        Label(state.devices.count > 1 ? "Phones" : "Add phone", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                    .help("Show pairing QR code or manage connected phones")
                    if state.peerFeatures.contains("file") {
                        Button {
                            FileSendPicker.pickAndSend()
                        } label: {
                            Label("Send files…", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if state.devices.count > 1 {
                    Divider()
                    HStack(spacing: 8) {
                        Text("Active phone:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(state.devices) { device in
                            let selected = device.id == state.activeDevice?.id
                            Button {
                                state.selectDevice(device.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(selected ? Color.green : Color.secondary.opacity(0.45))
                                        .frame(width: 6, height: 6)
                                    Text(device.name)
                                        .font(.caption.weight(selected ? .semibold : .regular))
                                    if let b = device.battery, b.hasLevel {
                                        Text("\(b.level)%")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(b.tint)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(selected
                                                   ? Color.accentColor.opacity(0.16)
                                                   : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    Capsule().stroke(
                                        selected ? Color.accentColor.opacity(0.4) : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - RAM Clipboard Hub

    private var clipboardHubCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Clipboard text sync", isOn: $prefs.clipboardSyncEnabled)
                            .toggleStyle(.switch)
                            .font(.headline)
                        Text(clipboardSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !state.clipHistory.isEmpty {
                        Button("Clear") {
                            state.clearClipHistory()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Clear in-memory clipboard history")
                    }
                }

                // One-off composer — works even when automatic sync is OFF.
                HStack(spacing: 8) {
                    TextField("Send text or link to phone…", text: $manualClipText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendManualClip() }
                    Button {
                        sendManualClip()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manualClipText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let feedback = clipSendFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if !state.clipHistory.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Session clips (RAM only)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Cleared on quit")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(state.clipHistory.prefix(5)) { item in
                            clipHistoryRow(item)
                        }
                    }
                }
            }
        }
    }

    private func clipHistoryRow(_ item: ClipHistoryItem) -> some View {
        let isCopied = copiedClipId == item.id
        return HStack(spacing: 8) {
            Image(systemName: item.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.direction == .incoming ? Color.blue : Color.green)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(item.text.replacingOccurrences(of: "\n", with: " "))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(item.at, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button {
                ClipboardSync.shared.copyToLocalPasteboard(item.text)
                copiedClipId = item.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    if copiedClipId == item.id { copiedClipId = nil }
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(isCopied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy to Mac clipboard")
            .accessibilityLabel("Copy clip to Mac clipboard")

            Button {
                if ClipboardSync.shared.sendManualText(item.text) {
                    flashClipFeedback("Sent to phone")
                }
            } label: {
                Image(systemName: "paperplane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Send to phone")
            .accessibilityLabel("Send clip to phone")
        }
        .padding(.vertical, 2)
    }

    private func sendManualClip() {
        let text = manualClipText
        guard ClipboardSync.shared.sendManualText(text) else { return }
        manualClipText = ""
        flashClipFeedback("Sent to \(state.pairedDeviceName ?? "phone")")
    }

    private func flashClipFeedback(_ msg: String) {
        clipSendFeedback = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if clipSendFeedback == msg { clipSendFeedback = nil }
        }
    }

    private var clipboardSubtitle: String {
        if let dir = state.lastClipDirection, let at = state.lastClipAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            let rel = f.localizedString(for: at, relativeTo: Date())
            return "\(dir == .incoming ? "Last received from phone" : "Last sent to phone") • \(rel)"
        }
        return prefs.clipboardSyncEnabled
            ? "Mirrors clipboard text between Mac and phone over your LAN."
            : "Auto-sync is off for privacy; you can still send one-off text below."
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlayingCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                nowPlayingArtwork
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.media.title ?? state.media.app ?? "Now playing")
                        .font(.headline).lineLimit(1)
                    if let artist = state.media.artist, !artist.isEmpty {
                        Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    } else if let app = state.media.app, !app.isEmpty {
                        Text(app).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Button { MediaController.shared.send(cmd: "prev") } label: {
                            Image(systemName: "backward.fill")
                        }
                        .disabled(!state.media.canSkipPrev)
                        .help("Previous track")
                        .accessibilityLabel("Previous track")

                        Button { MediaController.shared.send(cmd: "toggle") } label: {
                            Image(systemName: state.media.playing ? "pause.fill" : "play.fill")
                        }
                        .help(state.media.playing ? "Pause" : "Play")
                        .accessibilityLabel(state.media.playing ? "Pause" : "Play")

                        Button { MediaController.shared.send(cmd: "next") } label: {
                            Image(systemName: "forward.fill")
                        }
                        .disabled(!state.media.canSkipNext)
                        .help("Next track")
                        .accessibilityLabel("Next track")
                    }
                    .buttonStyle(.bordered)

                    if state.media.maxVolume > 0 {
                        overviewVolumeSlider
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var overviewVolumeSlider: some View {
        let maxV = Double(state.media.maxVolume)
        let current = pendingVolume ?? Double(state.media.volume)
        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { current }, set: { pendingVolume = $0 }),
                in: 0...maxV,
                step: 1,
                onEditingChanged: { editing in
                    if !editing, let v = pendingVolume {
                        MediaController.shared.send(cmd: "vol_set", value: Int(v.rounded()))
                    }
                }
            )
            .accessibilityLabel("Phone media volume")
            .accessibilityValue("\(Int(current)) of \(Int(maxV))")
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(Int(current))/\(Int(maxV))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var nowPlayingArtwork: some View {
        if let b64 = state.media.artworkBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable().interpolation(.medium).scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Active transfers + recent notifications

    private func activeTransfersCard(items: [TransferProgress]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Active transfers").font(.headline)
                    Spacer()
                    Button("See all") {
                        MainWindowSelection.shared.pending = .transfers
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                ForEach(items, id: \.id) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.direction == .incoming
                              ? "arrow.down.circle.fill"
                              : "arrow.up.circle.fill")
                            .foregroundStyle(t.direction == .incoming ? .blue : .green)
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).lineLimit(1)
                            ProgressView(value: progressValue(t)).frame(maxWidth: .infinity)
                        }
                        Text("\(Int(progressValue(t) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Button {
                            FileTransferCenter.shared.cancel(xid: t.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel transfer")
                        .accessibilityLabel("Cancel transfer \(t.name)")
                    }
                }
            }
        }
    }

    private var recentNotificationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent notifications").font(.headline)
                    Spacer()
                    if history.entries.count > 5 {
                        Button {
                            MainWindowSelection.shared.pending = .notifications
                        } label: {
                            HStack(spacing: 4) {
                                Text("See all")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                }

                if history.entries.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Nothing yet — notifications from your phone will land here.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                } else {
                    let recent = Array(history.entries.prefix(5))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, entry in
                        OverviewNotificationRow(entry: entry) {
                            MainWindowSelection.shared.pending = .notifications
                            MainWindowSelection.shared.pendingNotificationKey = entry.key
                        }
                        if idx < recent.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func progressValue(_ t: TransferProgress) -> Double {
        t.size > 0 ? min(1, Double(t.bytesTransferred) / Double(t.size)) : 0
    }
}

private struct OverviewNotificationRow: View {
    let entry: NotificationHistory.Entry
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.app).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.receivedAt,
                                 format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        if !entry.title.isEmpty {
                            Text(entry.title).font(.body.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        if !entry.body.isEmpty {
                            Text(entry.body).font(.body).lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Notifications")
            .accessibilityLabel("\(entry.app): \(entry.title). \(entry.body)")

            if let code = entry.extractedCode {
                CodeChip(code: code)
                    .padding(.leading, 48)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
        }
    }
}
