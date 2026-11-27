import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar sections

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case notifications
    case transfers
    case files
    case apps
    case settings

    var id: String { rawValue }

    static let bridgeCases: [MainSection] = [.overview, .notifications, .transfers]
    static let manageCases: [MainSection] = [.files, .apps, .settings]

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .notifications: return "Notifications"
        case .transfers: return "File Transfers"
        case .files: return "Phone Files"
        case .apps: return "Mirrored Apps"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "circle.grid.2x2.fill"
        case .notifications: return "bell.badge.fill"
        case .transfers: return "arrow.up.arrow.down.circle.fill"
        case .files: return "folder.fill"
        case .apps: return "square.grid.3x3.square"
        case .settings: return "gearshape.fill"
        }
    }
}

// Global deep-link selection used by the menu-bar popup to jump directly
// to a section when the main window opens.
@MainActor
final class MainWindowSelection: ObservableObject {
    static let shared = MainWindowSelection()
    @Published var pending: MainSection? = nil
    /// When set, the Notifications pane scrolls to and highlights this key,
    /// then clears the field. Used by the macOS notification-click handler.
    @Published var pendingNotificationKey: String? = nil
    @Published var showPairingSheet: Bool = false
    private init() {}

    func openPairing(isConnected: Bool) {
        pending = .overview
        showPairingSheet = isConnected
    }
}

// MARK: - Main window

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = NotificationHistory.shared
    @ObservedObject private var selectionBridge = MainWindowSelection.shared
    @State private var selection: MainSection? = .overview
    @State private var isDropTarget: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 580)
        .onAppear {
            consumePending()
            DockIconController.shared.acquire()
        }
        .onDisappear {
            DockIconController.shared.release()
        }
        .onChange(of: selectionBridge.pending) { _, _ in consumePending() }
        .sheet(isPresented: $selectionBridge.showPairingSheet) {
            PairingSheet()
                .environmentObject(state)
        }
        .overlay {
            if isDropTarget { dropOverlay }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
    }

    private var canAcceptFiles: Bool {
        state.isClientConnected && state.peerFeatures.contains("file")
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(canAcceptFiles ? 0.18 : 0.10)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: canAcceptFiles
                      ? "paperplane.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(canAcceptFiles ? Color.accentColor : .orange)
                Text(canAcceptFiles
                     ? "Drop to send to \(state.pairedDeviceName ?? "phone")"
                     : "Connect a phone to send files")
                    .font(.title2.weight(.semibold))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(radius: 14)
            )
            .padding(40)
        }
        .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptFiles else { return false }
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

    private func consumePending() {
        if let target = selectionBridge.pending {
            selection = target
            selectionBridge.pending = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if state.devices.count > 1 {
                sidebarDeviceSwitcher
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if state.isMirroringPaused {
                sidebarPauseBanner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            List(selection: $selection) {
                Section("Bridge") {
                    ForEach(MainSection.bridgeCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(sidebarBadge(section))
                            .tag(section)
                    }
                }
                Section("Phone & Setup") {
                    ForEach(MainSection.manageCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(sidebarBadge(section))
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(headerTint.opacity(0.20))
                Image(systemName: headerSymbol)
                    .foregroundStyle(headerTint)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("NotifMirror")
                    .font(.headline)
                Text(sidebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var sidebarSubtitle: String {
        if state.devices.count > 1 {
            return "\(state.devices.count) phones connected"
        }
        return state.isClientConnected
            ? (state.pairedDeviceName ?? "Paired phone")
            : "Waiting for phone…"
    }

    private var sidebarDeviceSwitcher: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.devices) { device in
                let isSelected = device.id == state.activeDevice?.id
                Button {
                    state.selectDevice(device.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSelected ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(device.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let b = device.battery, b.hasLevel {
                            Text("\(b.level)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(b.tint)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Target \(device.name) for file send, clipboard, and Phone Files")
            }
        }
    }

    private var headerSymbol: String {
        if state.isMirroringPaused { return "bell.slash.fill" }
        return state.isClientConnected ? "bell.badge.fill" : "bell"
    }

    private var headerTint: Color {
        if state.isMirroringPaused { return .orange }
        return state.isClientConnected ? .green : .secondary
    }

    private var sidebarPauseBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.slash.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(state.pauseLabel ?? "Banners paused")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Resume") {
                state.resumeMirroring()
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        )
    }

    private func sidebarBadge(_ section: MainSection) -> Int {
        switch section {
        case .notifications: return history.entries.count
        case .transfers: return state.transfers.values.filter { $0.isInFlight }.count
        default: return 0
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:       OverviewPane()
        case .notifications:  NotificationsPane()
        case .transfers:      TransfersPane()
        case .files:          FilesPane()
        case .apps:           MirroredAppsPane()
        case .settings:       SettingsPane()
        }
    }
}

// MARK: - Pairing sheet

struct PairingSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pairing", systemImage: "qrcode")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close pairing dialog")
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if !state.devices.isEmpty {
                        connectedDevicesCard
                    }
                    qrCard
                }
                .padding(22)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 480, idealHeight: 580)
    }

    private var connectedDevicesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        state.devices.count == 1
                            ? "1 phone connected"
                            : "\(state.devices.count) phones connected",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.green)
                    Spacer()
                }
                Text("Scan the QR code below on another Android phone to connect multiple devices simultaneously.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(state.devices) { device in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.host ?? "LAN TLS")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let b = device.battery, b.hasLevel {
                            Text("\(b.level)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(b.tint)
                        }
                        Button("Disconnect") {
                            WsServer.shared.disconnectDevice(device.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var qrCard: some View {
        if let payload = makePayload() {
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

                    VStack(alignment: .leading, spacing: 4) {
                        infoRow(symbol: "network", label: "Host",
                                value: LocalAddress.currentLanIPv4())
                        infoRow(symbol: "number.circle", label: "Port",
                                value: state.listenerPort == 0 ? "(starting…)" : String(state.listenerPort))
                        infoRow(symbol: "laptopcomputer", label: "Mac",
                                value: Host.current().localizedName ?? "Mac")
                    }
                    .frame(maxWidth: 340, alignment: .leading)

                    HStack(spacing: 12) {
                        CopyPayloadButton(payload: payload)
                        RegenerateSecretButton(title: "Regenerate")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Card {
                ProgressView("Starting server…")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }

    private func infoRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func makePayload() -> String? {
        guard state.listenerPort != 0 else { return nil }
        return Pairing.shared.payloadJSON(
            host: LocalAddress.currentLanIPv4(),
            port: Int(state.listenerPort)
        )
    }
}
