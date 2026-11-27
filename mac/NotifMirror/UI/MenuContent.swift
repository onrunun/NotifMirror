import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var history = NotificationHistory.shared
    @Environment(\.openWindow) private var openWindow

    @State private var pendingVolume: Double? = nil
    @State private var quickText: String = ""
    @State private var quickSentFlash: Bool = false
    @State private var copiedLatestClip: Bool = false
    @State private var isDropTarget: Bool = false

    private var canSendFiles: Bool {
        state.isClientConnected && state.peerFeatures.contains("file")
    }

    private var canUseClip: Bool {
        state.isClientConnected && state.peerFeatures.contains("clip")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.devices.count > 1 {
                deviceSwitcherStrip
            }

            controlTiles

            if canUseClip {
                quickClipboardBar
            }

            let activeTransfers = state.transfers.values
                .filter { $0.isInFlight }
                .sorted { $0.startedAt > $1.startedAt }
            if !activeTransfers.isEmpty {
                activeTransfersStrip(items: activeTransfers)
            }

            if state.isClientConnected
                && state.peerFeatures.contains("media")
                && prefs.mediaControlEnabled
                && state.media.hasSession {
                Divider()
                miniPlayer
            }

            if !history.entries.isEmpty {
                Divider()
                recentNotifications
            }

            if let err = state.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            footerStrip
        }
        .padding(12)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(canSendFiles ? Color.accentColor : Color.orange, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill((canSendFiles ? Color.accentColor : Color.orange).opacity(0.10))
                    )
                    .overlay {
                        Label(
                            canSendFiles
                                ? "Drop to send to \(state.pairedDeviceName ?? "phone")"
                                : "Connect phone to send files",
                            systemImage: canSendFiles ? "paperplane.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        .onChange(of: state.media.volume) { _, _ in pendingVolume = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(statusTint.opacity(0.20))
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.isClientConnected
                     ? (state.pairedDeviceName ?? "Connected")
                     : "Waiting for phone…")
                    .font(.headline)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.isMirroringPaused ? .orange : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if state.isClientConnected,
               state.peerFeatures.contains("battery"),
               let battery = state.battery {
                batteryBadge(battery)
            }

            Button {
                MainWindowSelection.shared.openPairing(isConnected: state.isClientConnected)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Pairing QR (⌘P)")
            .accessibilityLabel("Show Pairing QR")
            .keyboardShortcut("p")

            Button {
                openMain(section: .overview)
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Open NotifMirror window (⌘O)")
            .accessibilityLabel("Open NotifMirror window")
            .keyboardShortcut("o")
        }
    }

    private var statusSymbol: String {
        if state.isMirroringPaused { return "bell.slash.fill" }
        return state.isClientConnected ? "bell.badge.fill" : "bell"
    }

    private var statusTint: Color {
        if state.isMirroringPaused { return .orange }
        return state.isClientConnected ? .green : .secondary
    }

    private var headerSubtitle: String {
        if let pause = state.pauseLabel { return pause }
        let port = state.listenerPort == 0 ? "—" : String(state.listenerPort)
        if state.devices.count > 1 {
            return "\(state.devices.count) phones • \(history.entries.count) in history"
        }
        return "Port \(port) • \(history.entries.count) in history"
    }

    private var deviceSwitcherStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.devices) { device in
                    let active = device.id == state.activeDevice?.id
                    Button {
                        state.selectDevice(device.id)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(active ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(device.name)
                                .font(.caption.weight(active ? .semibold : .regular))
                                .lineLimit(1)
                            if let b = device.battery, b.hasLevel {
                                Text("\(b.level)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(b.tint)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(active
                                           ? Color.accentColor.opacity(0.16)
                                           : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            Capsule().stroke(
                                active ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.08),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func batteryBadge(_ b: BatterySnapshot) -> some View {
        HStack(spacing: 3) {
            Image(systemName: b.sfSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(b.tint)
            Text(b.hasLevel ? "\(b.level)%" : "—")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(b.tint)
        }
        .help(batteryTooltip(b))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phone battery: \(batteryTooltip(b))")
    }

    private func batteryTooltip(_ b: BatterySnapshot) -> String {
        var parts: [String] = []
        if b.hasLevel { parts.append("\(b.level)%") }
        if b.charging { parts.append("charging") }
        if b.plugged != "none" && b.plugged != "unknown" { parts.append("via \(b.plugged)") }
        if let t = b.temperatureC { parts.append(String(format: "%.1f°C", t)) }
        return parts.isEmpty ? "Battery state unknown" : parts.joined(separator: " • ")
    }

    // MARK: - 2×2 Control Center Tiles

    private var controlTiles: some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            pauseTile
            clipboardTile
            sendFilesTile
            screenMirrorTile
        }
    }

    @ViewBuilder
    private var pauseTile: some View {
        if state.isMirroringPaused {
            Button {
                state.resumeMirroring()
            } label: {
                tileChrome(
                    symbol: "bell.slash.fill",
                    title: "Paused",
                    subtitle: "Click to resume",
                    active: true,
                    tint: .orange
                )
            }
            .buttonStyle(.plain)
            .help("Resume notification banners")
        } else {
            Menu {
                Button("Pause for 30 minutes") { state.pauseMirroring(for: 30 * 60) }
                Button("Pause for 1 hour") { state.pauseMirroring(for: 60 * 60) }
                Divider()
                Button("Pause until resumed") { state.pauseMirroring(for: nil) }
            } label: {
                tileChrome(
                    symbol: "bell.slash",
                    title: "Pause banners",
                    subtitle: "Presentation mode",
                    active: false,
                    tint: .orange
                )
            }
            .menuStyle(.borderlessButton)
            .help("Temporarily hide macOS banners while presenting or focusing")
        }
    }

    private var clipboardTile: some View {
        Button {
            prefs.clipboardSyncEnabled.toggle()
        } label: {
            tileChrome(
                symbol: "doc.on.clipboard",
                title: "Clipboard sync",
                subtitle: clipboardTileSubtitle,
                active: prefs.clipboardSyncEnabled,
                tint: .accentColor
            )
        }
        .buttonStyle(.plain)
        .disabled(!canUseClip)
        .opacity(canUseClip ? 1 : 0.5)
        .help("Toggle automatic clipboard text sync over LAN")
    }

    private var clipboardTileSubtitle: String {
        if !canUseClip { return "Phone offline" }
        if prefs.clipboardSyncEnabled {
            if let dir = state.lastClipDirection, let at = state.lastClipAt {
                return "\(dir == .incoming ? "←" : "→") \(Self.relative(at))"
            }
            return "Active"
        }
        return "Off"
    }

    private var sendFilesTile: some View {
        Button {
            FileSendPicker.pickAndSend()
        } label: {
            tileChrome(
                symbol: "paperplane.fill",
                title: "Send files",
                subtitle: canSendFiles ? "Click or drop here" : "Phone offline",
                active: isDropTarget && canSendFiles,
                tint: .accentColor
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSendFiles)
        .opacity(canSendFiles ? 1 : 0.5)
        .help("Send files to phone, or drag and drop onto this popover")
    }

    private var screenMirrorTile: some View {
        Button {
            ScreenMirror.shared.toggle()
        } label: {
            tileChrome(
                symbol: state.scrcpyRunning ? "display" : "display",
                title: "Mirror screen",
                subtitle: state.scrcpyRunning ? "Running — stop" : "scrcpy",
                active: state.scrcpyRunning,
                tint: .green
            )
        }
        .buttonStyle(.plain)
        .help(state.scrcpyRunning ? "Stop scrcpy screen mirror" : "Start scrcpy screen mirror")
    }

    private func tileChrome(
        symbol: String,
        title: String,
        subtitle: String,
        active: Bool,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(active ? tint : Color.primary.opacity(0.08))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(active ? tint : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? tint.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(active ? tint.opacity(0.38) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Quick Send Text & Latest Clip

    private var quickClipboardBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Send text or link to phone…", text: $quickText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { sendQuickText() }
                Button {
                    sendQuickText()
                } label: {
                    Image(systemName: quickSentFlash ? "checkmark" : "paperplane.fill")
                        .foregroundStyle(quickSentFlash ? Color.green : Color.accentColor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !quickSentFlash)
                .help("Send text to phone clipboard")
                .accessibilityLabel("Send text to phone clipboard")
            }

            if let latest = state.clipHistory.first(where: { $0.direction == .incoming }) {
                Button {
                    ClipboardSync.shared.copyToLocalPasteboard(latest.text)
                    copiedLatestClip = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedLatestClip = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedLatestClip ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(copiedLatestClip ? .green : .secondary)
                        Text(copiedLatestClip
                             ? "Copied latest phone clip"
                             : "Phone clip: \(latest.text.replacingOccurrences(of: "\n", with: " "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .help("Copy latest clip received from phone")
            }
        }
    }

    private func sendQuickText() {
        guard ClipboardSync.shared.sendManualText(quickText) else { return }
        quickText = ""
        quickSentFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quickSentFlash = false }
    }

    // MARK: - Active Transfers Strip

    private func activeTransfersStrip(items: [TransferProgress]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.prefix(2), id: \.id) { t in
                let pct = t.size > 0 ? min(1, Double(t.bytesTransferred) / Double(t.size)) : 0
                HStack(spacing: 6) {
                    Image(systemName: t.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(t.direction == .incoming ? .blue : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.caption).lineLimit(1)
                        ProgressView(value: pct).controlSize(.small)
                    }
                    Text("\(Int(pct * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Button {
                        FileTransferCenter.shared.cancel(xid: t.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel transfer")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Recent Notifications (with inline 2FA + Quick Reply)

    private var recentNotifications: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if history.entries.count > 3 {
                    Button {
                        openMain(section: .notifications)
                    } label: {
                        Text("See all (\(history.entries.count))")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.borderless)
                }
            }
            ForEach(Array(history.entries.prefix(3))) { entry in
                MenuRecentRow(
                    entry: entry,
                    canReply: state.isClientConnected,
                    showDeviceBadge: state.devices.count > 1
                ) {
                    MainWindowSelection.shared.pendingNotificationKey = entry.key
                    openMain(section: .notifications)
                }
            }
        }
    }

    // MARK: - Mini Player

    private var miniPlayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                artworkView

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.media.title ?? state.media.app ?? "Playing")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let artist = state.media.artist, !artist.isEmpty {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        transportButton("backward.fill", label: "Previous track", enabled: state.media.canSkipPrev) {
                            MediaController.shared.send(cmd: "prev")
                        }
                        transportButton(
                            state.media.playing ? "pause.fill" : "play.fill",
                            label: state.media.playing ? "Pause" : "Play",
                            enabled: true
                        ) {
                            MediaController.shared.send(cmd: "toggle")
                        }
                        transportButton("forward.fill", label: "Next track", enabled: state.media.canSkipNext) {
                            MediaController.shared.send(cmd: "next")
                        }
                    }
                }
            }

            if state.media.maxVolume > 0 { volumeControl }
        }
    }

    private var volumeControl: some View {
        let maxV = Double(state.media.maxVolume)
        let current = pendingVolume ?? Double(state.media.volume)
        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { current }, set: { pendingVolume = $0 }),
                in: 0...maxV, step: 1,
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
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        let size: CGFloat = 46
        if let b64 = state.media.artworkBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                .accessibilityHidden(true)
        }
    }

    private func transportButton(
        _ systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Footer Strip

    private var footerStrip: some View {
        HStack(spacing: 4) {
            footerButton("folder.fill", "Files", .files, "f")
            footerButton("bell.badge.fill", "Inbox", .notifications, "n")
            footerButton("gearshape.fill", "Settings", .settings, ",")
            Spacer(minLength: 4)
            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .help("Quit NotifMirror (⌘Q)")
        }
    }

    private func footerButton(
        _ symbol: String,
        _ title: String,
        _ section: MainSection,
        _ shortcut: KeyEquivalent
    ) -> some View {
        Button {
            openMain(section: section)
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut)
    }

    // MARK: - Helpers

    private func openMain(section: MainSection) {
        MainWindowSelection.shared.pending = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canSendFiles else { return false }
        var accepted = 0
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    FileTransferCenter.shared.sendFile(url: url)
                }
            }
            accepted += 1
        }
        return accepted > 0
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct MenuRecentRow: View {
    let entry: NotificationHistory.Entry
    let canReply: Bool
    let showDeviceBadge: Bool
    let onOpen: () -> Void

    @State private var replying: Bool = false
    @State private var replyText: String = ""
    @State private var sentFlash: Bool = false

    private var replyAction: ActionDescriptor? {
        entry.actions?.first(where: \.isReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(showDeviceBadge && entry.deviceName != nil
                                 ? "\(entry.app) • \(entry.deviceName!)"
                                 : entry.app)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(entry.receivedAt,
                                 format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(primaryText)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.app): \(primaryText)")

            if entry.extractedCode != nil || (replyAction != nil && canReply) || sentFlash {
                HStack(spacing: 6) {
                    if let code = entry.extractedCode {
                        CodeChip(code: code, compact: true)
                    }
                    if let action = replyAction, canReply {
                        Button {
                            replying.toggle()
                            if !replying { replyText = "" }
                        } label: {
                            Label(replying ? "Close" : action.title, systemImage: "arrowshape.turn.up.left.fill")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    if sentFlash {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.leading, 42)
            }

            if replying, let action = replyAction, canReply {
                HStack(spacing: 6) {
                    TextField("Reply…", text: $replyText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { submitReply(action) }
                    Button("Send") { submitReply(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 42)
                .padding(.trailing, 4)
                .padding(.bottom, 2)
            }
        }
    }

    private func submitReply(_ action: ActionDescriptor) {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if WsServer.shared.sendAction(key: entry.key, actionId: action.id, text: trimmed, to: entry.deviceId) {
            replyText = ""
            replying = false
            sentFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { sentFlash = false }
        }
    }

    private var primaryText: String {
        if !entry.title.isEmpty && !entry.body.isEmpty {
            return "\(entry.title) — \(entry.body)"
        }
        return entry.title.isEmpty ? entry.body : entry.title
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        }
    }
}
