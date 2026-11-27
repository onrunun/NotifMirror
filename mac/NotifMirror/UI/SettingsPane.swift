import AppKit
import SwiftUI
import UserNotifications

struct SettingsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var appState = AppState.shared
    @State private var inboxPathEditing: String = ""
    @State private var notifDiagnostic: NotifDiagnostic? = nil
    @State private var e2eDiagnostic: NotifDiagnostic? = nil
    @State private var e2ePending: Bool = false

    private struct NotifDiagnostic: Identifiable {
        let id = UUID()
        let ok: Bool
        let message: String
        var technicalDetails: String? = nil
    }

    var body: some View {
        PaneContainer("Settings", subtitle: "Configure NotifMirror, diagnostics, and optional tools.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalCard
                    featuresCard
                    filesCard
                    screenMirrorCard
                    diagnosticsCard
                    dangerCard
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
        .onAppear { inboxPathEditing = prefs.fileInboxPath }
    }

    private var generalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("General").font(.headline)
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle(isOn: $prefs.hideSilent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide silent notifications")
                        Text("Skip banners from silent or background Android notification channels.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var featuresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bridge features").font(.headline)
                Toggle(isOn: $prefs.clipboardSyncEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clipboard text sync")
                        Text("Mirrors clipboard text over your LAN. Off by default because clipboards often hold passwords or 2FA codes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $prefs.mediaControlEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Media control")
                        Text("Show phone now-playing info and playback controls in the menu bar and Overview.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var filesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Incoming files").font(.headline)
                Text("Files shared from your phone and default Phone Files downloads are saved here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Incoming folder path", text: $inboxPathEditing)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitInboxPath() }
                        .onChange(of: inboxPathEditing) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { prefs.fileInboxPath = trimmed }
                        }
                    Button("Choose…") { chooseInbox() }
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(nil,
                            inFileViewerRootedAtPath: prefs.fileInboxPath)
                    }
                }
            }
        }
    }

    private var screenMirrorCard: some View {
        let hasScrcpy = ScreenMirror.shared.isScrcpyInstalled
        let hasAdb = ScreenMirror.shared.isAdbInstalled
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(appState.scrcpyRunning
                                  ? Color.green.opacity(0.22)
                                  : Color.secondary.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: appState.scrcpyRunning ? "display" : "display.trianglebadge.exclamationmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(appState.scrcpyRunning ? .green : .secondary)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Mirror (scrcpy)").font(.headline)
                        Text(appState.scrcpyRunning
                             ? "scrcpy is showing your phone. Close its window or click Stop."
                             : "Optional developer feature — launches scrcpy over USB or wireless adb.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        ScreenMirror.shared.toggle()
                    } label: {
                        Label(appState.scrcpyRunning ? "Stop" : "Start mirroring",
                              systemImage: appState.scrcpyRunning ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.scrcpyRunning ? .red : .accentColor)
                    .disabled(!appState.scrcpyRunning && !hasScrcpy)
                }

                HStack(spacing: 14) {
                    prereqBadge("scrcpy", ok: hasScrcpy)
                    prereqBadge("adb", ok: hasAdb)
                    if !hasScrcpy || !hasAdb {
                        Text("Install via: brew install scrcpy")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let err = appState.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func prereqBadge(_ name: String, ok: Bool) -> some View {
        Label(name, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(ok ? .green : .orange)
    }

    private var dangerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pairing & security").font(.headline)
                Text("View the QR code or rotate the 256-bit shared secret (invalidates current pairing).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        MainWindowSelection.shared.showPairingSheet = true
                    } label: {
                        Label("Show pairing QR…", systemImage: "qrcode")
                    }
                    RegenerateSecretButton(title: "Regenerate pairing secret") {
                        MainWindowSelection.shared.openPairing(isConnected: false)
                    }
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notification diagnostics").font(.headline)
                Text("Send a local test banner. If it doesn't appear, macOS is suppressing NotifMirror banners (check Focus Mode, Do Not Disturb, or \"Deliver Quietly\").")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await sendTestNotification() }
                    } label: {
                        Label("Send test notification", systemImage: "bell.and.waves.left.and.right")
                    }
                    Button {
                        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open Notification Settings", systemImage: "gear")
                    }
                }
                if let diag = notifDiagnostic {
                    diagnosticView(diag)
                }

                Divider().padding(.vertical, 2)

                Text("End-to-end test").font(.subheadline).bold()
                Text("Asks the paired Android phone to fire a test notification so the listener catches and mirrors it back over the live TLS connection.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await sendEndToEndTest() }
                    } label: {
                        if e2ePending {
                            Label("Waiting for Android…", systemImage: "hourglass")
                        } else {
                            Label("Run end-to-end test", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(e2ePending || !appState.isClientConnected)
                    if !appState.isClientConnected {
                        Text("Android not connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let diag = e2eDiagnostic {
                    diagnosticView(diag)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticView(_ diag: NotifDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(diag.message,
                  systemImage: diag.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(diag.ok ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            if let details = diag.technicalDetails {
                DisclosureGroup("Technical details") {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func commitInboxPath() {
        let trimmed = inboxPathEditing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prefs.fileInboxPath = trimmed
        } else {
            inboxPathEditing = prefs.fileInboxPath
        }
    }

    @MainActor
    private func sendEndToEndTest() async {
        guard appState.isClientConnected else {
            e2eDiagnostic = .init(ok: false, message: "Not connected to Android.")
            return
        }
        let reqId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        appState.pendingE2ETestReqId = reqId
        e2eDiagnostic = nil
        e2ePending = true
        defer { e2ePending = false }

        WsServer.shared.sendTestRequest(reqId: reqId)

        let started = Date()
        let timeout: TimeInterval = 5.0
        while Date().timeIntervalSince(started) < timeout {
            if appState.pendingE2ETestReqId != reqId {
                e2eDiagnostic = .init(
                    ok: true,
                    message: "Round-trip OK — received mirrored test from Android in \(Int(Date().timeIntervalSince(started) * 1000)) ms."
                )
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if appState.pendingE2ETestReqId == reqId {
            appState.pendingE2ETestReqId = nil
        }
        e2eDiagnostic = .init(
            ok: false,
            message: "No mirrored test notification arrived within \(Int(timeout))s. On your phone, confirm both Notification Access and Own Notifications permissions are granted in NotifMirror."
        )
    }

    @MainActor
    private func sendTestNotification() async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                settings = await center.notificationSettings()
                if !granted {
                    notifDiagnostic = .init(
                        ok: false,
                        message: "Permission prompt declined. Enable it in System Settings › Notifications › NotifMirror."
                    )
                    return
                }
            } catch {
                notifDiagnostic = .init(
                    ok: false,
                    message: "Authorization request failed: \(error.localizedDescription).",
                    technicalDetails: Self.settingsDump(settings)
                )
                return
            }
        }

        switch settings.authorizationStatus {
        case .denied:
            notifDiagnostic = .init(
                ok: false,
                message: "Notifications are disabled for NotifMirror. Open System Settings › Notifications › NotifMirror and turn them on.",
                technicalDetails: Self.settingsDump(settings)
            )
            return
        case .notDetermined:
            let bundleId = Bundle.main.bundleIdentifier ?? "com.notifmirror.app"
            notifDiagnostic = .init(
                ok: false,
                message: "macOS still reports notification permission as undetermined (common after rebuilding with a different signature).",
                technicalDetails: "Reset via Terminal: tccutil reset All \(bundleId)\n\(Self.settingsDump(settings))"
            )
            return
        default:
            break
        }
        if settings.alertSetting == .disabled && settings.notificationCenterSetting == .disabled {
            notifDiagnostic = .init(
                ok: false,
                message: "Both banners and Notification Center are off for NotifMirror in System Settings › Notifications.",
                technicalDetails: Self.settingsDump(settings)
            )
            return
        }
        if settings.alertStyle == .none || settings.alertSetting == .disabled {
            notifDiagnostic = .init(
                ok: false,
                message: "Banner style is set to None. Pick Banners or Alerts in System Settings › Notifications › NotifMirror.",
                technicalDetails: Self.settingsDump(settings)
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "NotifMirror test"
        content.body = "If you see this banner, macOS delivery is working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "notifmirror.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            notifDiagnostic = .init(
                ok: true,
                message: "Test posted. If no banner appeared, check Focus/DND, \"Deliver Quietly\", or re-toggle Allow Notifications in System Settings.",
                technicalDetails: Self.settingsDump(settings)
            )
        } catch {
            notifDiagnostic = .init(
                ok: false,
                message: "Failed to post notification: \(error.localizedDescription)",
                technicalDetails: Self.settingsDump(settings)
            )
        }
    }

    private static func settingsDump(_ s: UNNotificationSettings) -> String {
        "[auth=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue) center=\(s.notificationCenterSetting.rawValue) sound=\(s.soundSetting.rawValue)]"
    }

    private func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: prefs.fileInboxPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.fileInboxPath = url.path
            inboxPathEditing = url.path
        }
    }
}
