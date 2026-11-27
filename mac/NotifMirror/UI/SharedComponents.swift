import AppKit
import SwiftUI

/// Standard page chrome shared across every pane of the macOS window.
struct PaneContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Flat native card container — `controlBackgroundColor` + 1pt hairline border,
/// zero drop shadows ("The Quiet Bridge").
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

/// Pause / Presentation mode control shared between OverviewPane and MenuContent.
struct PauseMirroringMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.isMirroringPaused {
            Button {
                state.resumeMirroring()
            } label: {
                Label("Resume banners", systemImage: "bell.badge.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help(state.pauseLabel ?? "Resume notification banners")
        } else {
            Menu {
                Button("Pause for 30 minutes") { state.pauseMirroring(for: 30 * 60) }
                Button("Pause for 1 hour") { state.pauseMirroring(for: 60 * 60) }
                Divider()
                Button("Pause until resumed") { state.pauseMirroring(for: nil) }
            } label: {
                Label("Pause", systemImage: "bell.slash")
            }
            .menuStyle(.borderedButton)
            .help("Hide notification banners during screen sharing or focus (notifications stay in history)")
        }
    }
}

/// Unified 2FA verification-code copy pill shared by MenuContent, OverviewPane,
/// and NotificationsPane so every surface speaks one visual grammar.
struct CodeChip: View {
    let code: String
    var compact: Bool = false
    var onCopy: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        Button {
            if let onCopy {
                onCopy()
            } else {
                ClipboardSync.shared.copyToLocalPasteboard(code)
            }
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(compact ? .caption2 : .caption)
                Text(labelText)
                    .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
                    .fill(Color.accentColor.opacity(copied ? 0.28 : 0.16))
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied code \(code)" : "Copy verification code \(code)")
        .help("Copy code \(code)")
    }

    private var labelText: String {
        if copied { return "Copied" }
        return compact ? code : "Copy code \(code)"
    }
}

/// Copies a pairing JSON payload with brief confirmation feedback.
struct CopyPayloadButton: View {
    let payload: String
    var title: String = "Copy JSON"

    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(payload, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Label(copied ? "Copied" : title,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel(copied ? "Pairing JSON copied" : "Copy pairing JSON to clipboard")
    }
}

/// Confirmed destructive action for rotating the 256-bit pairing secret.
struct RegenerateSecretButton: View {
    var title: String = "Regenerate secret"
    var onRegenerated: (() -> Void)? = nil

    @State private var confirmOpen = false

    var body: some View {
        Button(role: .destructive) {
            confirmOpen = true
        } label: {
            Label(title, systemImage: "arrow.triangle.2.circlepath")
        }
        .confirmationDialog(
            "Regenerate pairing secret?",
            isPresented: $confirmOpen,
            titleVisibility: .visible
        ) {
            Button("Regenerate secret", role: .destructive) {
                _ = Pairing.shared.regenerateSecret()
                WsServer.shared.restartListener()
                AppState.shared.pairingRevision &+= 1
                onRegenerated?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects any paired phone and invalidates the current QR code. You will need to scan the new code on your Android device.")
        }
    }
}

/// Shared file picker helper for sending one or more local files to the phone.
@MainActor
enum FileSendPicker {
    static func pickAndSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                FileTransferCenter.shared.sendFile(url: url)
            }
        }
    }
}
