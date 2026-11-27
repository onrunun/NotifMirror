import AppKit
import SwiftUI

struct NotificationsPane: View {
    enum SmartFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case codes = "Codes"
        case replyable = "Replyable"
        var id: String { rawValue }
    }

    @EnvironmentObject var state: AppState
    @StateObject private var history = NotificationHistory.shared
    @StateObject private var blockedApps = BlockedApps.shared
    @ObservedObject private var selectionBridge = MainWindowSelection.shared
    @State private var query: String = ""
    @State private var selectedPkg: String? = nil
    @State private var smartFilter: SmartFilter = .all
    @State private var highlightedKey: String? = nil
    @State private var confirmClear: Bool = false
    @State private var recentlyDeleted: NotificationHistory.Entry? = nil

    var body: some View {
        PaneContainer("Notifications",
                      subtitle: history.entries.isEmpty
                          ? "Mirrored notifications will appear here as they arrive."
                          : "Showing \(filtered.count) of \(history.entries.count)") {
            VStack(spacing: 0) {
                toolbar
                if !appsByCount.isEmpty || hasSmartMatches {
                    filterBar
                }
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView(
                        history.entries.isEmpty ? "No notifications yet" : "No matches",
                        systemImage: history.entries.isEmpty ? "bell.slash" : "magnifyingglass",
                        description: Text(history.entries.isEmpty
                            ? "Mirrored notifications will appear here as they arrive."
                            : "Try a different search or filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { entry in
                                    HistoryEntryRow(
                                        entry: entry,
                                        highlighted: highlightedKey == entry.key,
                                        canReply: state.isClientConnected,
                                        showDeviceBadge: state.devices.count > 1,
                                        onDelete: { deleteWithUndo(entry) }
                                    )
                                    .id(entry.id)
                                    .onTapGesture {
                                        if highlightedKey != nil { highlightedKey = nil }
                                    }
                                    Divider()
                                }
                            }
                        }
                        .task(id: selectionBridge.pendingNotificationKey) {
                            await consumePendingKey(proxy: proxy)
                        }
                    }
                }
                if let deleted = recentlyDeleted {
                    undoBar(deleted)
                }
            }
        }
        .confirmationDialog(
            clearConfirmTitle,
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button(clearButtonLabel, role: .destructive) {
                if let pkg = selectedPkg {
                    history.clear(pkg: pkg)
                    selectedPkg = nil
                } else {
                    history.clear()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removed notification history cannot be undone.")
        }
    }

    private func deleteWithUndo(_ entry: NotificationHistory.Entry) {
        if let prev = recentlyDeleted {
            history.deleteAttachment(at: prev.attachmentPath)
        }
        recentlyDeleted = entry
        history.remove(entry, preserveAttachment: true)
        let deletedId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if recentlyDeleted?.id == deletedId {
                history.deleteAttachment(at: recentlyDeleted?.attachmentPath)
                recentlyDeleted = nil
            }
        }
    }

    private func undoBar(_ entry: NotificationHistory.Entry) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("Deleted notification from \(entry.app)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Undo") {
                    history.restore(entry)
                    recentlyDeleted = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @MainActor
    private func consumePendingKey(proxy: ScrollViewProxy) async {
        guard let key = selectionBridge.pendingNotificationKey else { return }
        selectionBridge.pendingNotificationKey = nil

        if !query.isEmpty { query = "" }
        if selectedPkg != nil { selectedPkg = nil }
        if smartFilter != .all { smartFilter = .all }

        guard let target = history.entries.first(where: { $0.key == key }) else { return }
        highlightedKey = key

        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("Search title, body or app", text: $query)
                    .textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            Picker("Filter", selection: $smartFilter) {
                ForEach(SmartFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            Spacer()
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label(clearButtonLabel, systemImage: "trash")
            }
            .disabled(clearButtonDisabled)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private var hasSmartMatches: Bool {
        history.entries.contains { $0.extractedCode != nil || $0.hasReplyAction }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                appFilterChip(label: "All apps", pkg: nil, count: history.entries.count)
                ForEach(appsByCount, id: \.pkg) { row in
                    appFilterChip(label: row.name, pkg: row.pkg, count: row.count)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }
    }

    private func appFilterChip(label: String, pkg: String?, count: Int) -> some View {
        let selected = selectedPkg == pkg
        let isBlocked = pkg.map { blockedApps.isBlocked($0) } ?? false
        return HStack(spacing: 5) {
            Button {
                selectedPkg = pkg
            } label: {
                HStack(spacing: 5) {
                    Text(label)
                        .strikethrough(isBlocked, color: .secondary)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .font(.callout)
            }
            .buttonStyle(.plain)

            if let pkg {
                Button {
                    blockedApps.setBlocked(pkg, blocked: !isBlocked)
                } label: {
                    Image(systemName: isBlocked ? "bell.slash.fill" : "bell")
                        .font(.caption)
                        .foregroundStyle(isBlocked ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isBlocked ? "Unmute \(label)" : "Mute \(label)")
                .accessibilityLabel(isBlocked ? "Unmute \(label)" : "Mute \(label)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.20) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            if let pkg {
                Button(isBlocked ? "Unmute \(label)" : "Mute \(label)") {
                    blockedApps.setBlocked(pkg, blocked: !isBlocked)
                }
            }
        }
    }

    private var selectedAppName: String? {
        guard let pkg = selectedPkg else { return nil }
        return history.entries.first { $0.pkg == pkg }?.app
    }

    private var clearButtonLabel: String {
        if let name = selectedAppName { return "Clear \(name)" }
        return "Clear all"
    }

    private var clearConfirmTitle: String {
        if let name = selectedAppName { return "Clear notifications from \(name)?" }
        return "Clear all notification history?"
    }

    private var clearButtonDisabled: Bool {
        if let pkg = selectedPkg {
            return !history.entries.contains { $0.pkg == pkg }
        }
        return history.entries.isEmpty
    }

    private var appsByCount: [(pkg: String, name: String, count: Int)] {
        var counts: [String: (name: String, count: Int, lastAt: Date)] = [:]
        for e in history.entries {
            if var cur = counts[e.pkg] {
                cur.count += 1
                cur.name = e.app
                if e.receivedAt > cur.lastAt { cur.lastAt = e.receivedAt }
                counts[e.pkg] = cur
            } else {
                counts[e.pkg] = (name: e.app, count: 1, lastAt: e.receivedAt)
            }
        }
        return counts
            .map { (pkg: $0.key, name: $0.value.name, count: $0.value.count, lastAt: $0.value.lastAt) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
                return $0.pkg < $1.pkg
            }
            .map { (pkg: $0.pkg, name: $0.name, count: $0.count) }
    }

    private var filtered: [NotificationHistory.Entry] {
        var list = history.entries
        if let pkg = selectedPkg { list = list.filter { $0.pkg == pkg } }
        switch smartFilter {
        case .all: break
        case .codes: list = list.filter { $0.extractedCode != nil }
        case .replyable: list = list.filter { $0.hasReplyAction }
        }
        if !query.isEmpty {
            let q = query.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) ||
                $0.body.lowercased().contains(q) ||
                $0.app.lowercased().contains(q) ||
                $0.pkg.lowercased().contains(q)
            }
        }
        return list
    }
}

private struct HistoryEntryRow: View {
    let entry: NotificationHistory.Entry
    var highlighted: Bool = false
    let canReply: Bool
    var showDeviceBadge: Bool = false
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.app).font(.callout).foregroundStyle(.secondary)
                    if showDeviceBadge, let dev = entry.deviceName, !dev.isEmpty {
                        Text(dev)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if entry.silent {
                        Text("silent")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.18))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.receivedAt, format: relativeFormat)
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !entry.title.isEmpty {
                    Text(entry.title).font(.body.weight(.semibold))
                }
                if !entry.body.isEmpty {
                    Text(entry.body).font(.body).lineLimit(4)
                }
                if let code = entry.extractedCode {
                    CodeChip(code: code, onCopy: { ClipboardSync.shared.copyToLocalPasteboard(code) })
                        .padding(.top, 2)
                }
                if let actions = entry.actions, !actions.isEmpty {
                    HistoryActionBar(
                        key: entry.key,
                        deviceId: entry.deviceId,
                        actions: actions,
                        canSend: canReply
                    )
                    .padding(.top, 4)
                }
            }
            .textSelection(.enabled)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .opacity(0.65)
            .help("Delete notification")
            .accessibilityLabel("Delete notification from \(entry.app)")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Color.accentColor.opacity(highlighted ? 0.28 : 0))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 4)
                .opacity(highlighted ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .contentShape(Rectangle())
        .contextMenu {
            if let code = entry.extractedCode {
                Button("Copy code \(code)") { ClipboardSync.shared.copyToLocalPasteboard(code) }
            }
            if !entry.title.isEmpty {
                Button("Copy title") { ClipboardSync.shared.copyToLocalPasteboard(entry.title) }
            }
            if !entry.body.isEmpty {
                Button("Copy body") { ClipboardSync.shared.copyToLocalPasteboard(entry.body) }
            }
            Button("Copy title + body") {
                let text = [entry.title, entry.body].filter { !$0.isEmpty }.joined(separator: "\n")
                ClipboardSync.shared.copyToLocalPasteboard(text)
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Text("Delete") }
        }
    }

    private var relativeFormat: Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
        }
    }
}

private struct HistoryActionBar: View {
    let key: String
    let deviceId: String?
    let actions: [ActionDescriptor]
    let canSend: Bool

    @State private var openReplyId: String? = nil
    @State private var replyText: String = ""
    @State private var feedbackLabel: String? = nil
    @State private var feedbackFailed: Bool = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(actions, id: \.id) { action in
                    Button {
                        if action.isReply {
                            if openReplyId == action.id {
                                openReplyId = nil
                            } else {
                                openReplyId = action.id
                                replyText = ""
                                DispatchQueue.main.async { replyFocused = true }
                            }
                        } else {
                            send(action: action, text: nil)
                        }
                    } label: {
                        Label(action.title,
                              systemImage: action.isReply
                                  ? "arrowshape.turn.up.left.fill"
                                  : "bolt.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canSend)
                }
                Spacer(minLength: 0)
                if !canSend {
                    Text("Phone offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let msg = feedbackLabel {
                    Label(msg, systemImage: feedbackFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(feedbackFailed ? .orange : .green)
                        .transition(.opacity)
                }
            }

            if canSend,
               let actionId = openReplyId,
               let action = actions.first(where: { $0.id == actionId }) {
                HStack(spacing: 8) {
                    TextField("Type a reply…", text: $replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .onSubmit {
                            if !replyText.isEmpty { send(action: action, text: replyText) }
                        }
                    Button("Send") { send(action: action, text: replyText) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(replyText.isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Cancel") {
                        openReplyId = nil
                        replyText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }

    private func send(action: ActionDescriptor, text: String?) {
        let ok = WsServer.shared.sendAction(key: key, actionId: action.id, text: text, to: deviceId)
        feedbackFailed = !ok
        let label = ok ? "\(action.title) sent" : "Phone disconnected — not sent"
        feedbackLabel = label
        if ok {
            openReplyId = nil
            replyText = ""
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if feedbackLabel == label { feedbackLabel = nil }
        }
    }
}
