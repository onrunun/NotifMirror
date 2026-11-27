import AppKit
import SwiftUI

struct TransfersPane: View {
    @EnvironmentObject var state: AppState

    private var canSendFiles: Bool {
        state.isClientConnected && state.peerFeatures.contains("file")
    }

    var body: some View {
        PaneContainer("File Transfers",
                      subtitle: "Unified queue for direct shares and Phone Files downloads or uploads.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        HStack(spacing: 10) {
                            Button {
                                FileSendPicker.pickAndSend()
                            } label: {
                                Label("Send files to phone…", systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSendFiles)

                            Button {
                                MainWindowSelection.shared.pending = .files
                            } label: {
                                Label("Browse phone files", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)

                            Button("Clear finished") {
                                state.transfers = state.transfers.filter { $0.value.isInFlight }
                            }
                            .disabled(!hasFinished)

                            if !canSendFiles {
                                Text("Connect a paired phone to send files.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }

                    if state.transfers.isEmpty {
                        ContentUnavailableView(
                            "No transfers",
                            systemImage: "arrow.up.arrow.down.circle",
                            description: Text("Drop files onto this window, send from your phone, or download from Phone Files.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                    } else {
                        Card {
                            VStack(spacing: 0) {
                                let items = state.transfers.values.sorted { $0.startedAt > $1.startedAt }
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                                    TransferRow(
                                        transfer: t,
                                        canRetry: canSendFiles,
                                        showDeviceBadge: state.devices.count > 1
                                    )
                                    if idx < items.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }

    private var hasFinished: Bool {
        state.transfers.values.contains { !$0.isInFlight }
    }
}

private struct TransferRow: View {
    let transfer: TransferProgress
    let canRetry: Bool
    var showDeviceBadge: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .incoming
                  ? "arrow.down.circle.fill"
                  : "arrow.up.circle.fill")
                .foregroundStyle(transfer.direction == .incoming ? .blue : .green)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.name).lineLimit(1)
                    if showDeviceBadge, let dev = transfer.deviceName, !dev.isEmpty {
                        Text(dev)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                    if transfer.source == .filesBrowse {
                        Text("Phone Files")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }
                if transfer.isInFlight {
                    if transfer.size > 0 {
                        ProgressView(value: progress).frame(maxWidth: 320)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(statusLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
            }
            Spacer()
            trailingAction
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var trailingAction: some View {
        if transfer.isInFlight {
            Button("Cancel") {
                FileTransferCenter.shared.cancel(xid: transfer.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if isFailed, transfer.direction == .outgoing, transfer.sourceURL != nil {
            Button("Retry") {
                FileTransferCenter.shared.retry(xid: transfer.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canRetry)
        } else if case .done = transfer.status,
                  transfer.direction == .incoming,
                  let path = transfer.destinationPath {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal in Finder")
        }
    }

    private var isFailed: Bool {
        if case .failed = transfer.status { return true }
        return false
    }

    private var progress: Double {
        transfer.size > 0
            ? min(1, Double(transfer.bytesTransferred) / Double(transfer.size))
            : 0
    }

    private var statusLabel: String {
        switch transfer.status {
        case .pending: return "Waiting for phone…"
        case .active:
            if transfer.size > 0 {
                let pct = Int(Double(transfer.bytesTransferred) / Double(transfer.size) * 100)
                return "\(pct)% • \(byteString(transfer.bytesTransferred)) / \(byteString(transfer.size))"
            }
            return "In progress…"
        case .done:
            let countPart = transfer.itemCount > 1 ? "\(transfer.itemCount) files • " : ""
            return transfer.size > 0 ? "Done • \(countPart)\(byteString(transfer.size))" : "Done"
        case .failed(let m): return "Failed: \(m)"
        case .cancelled: return "Cancelled"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
