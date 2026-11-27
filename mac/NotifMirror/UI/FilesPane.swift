import AppKit
import QuickLook
import SwiftUI

struct FilesPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FilesModel()
    @AppStorage("filesViewMode") private var viewModeRaw: String = FilesViewMode.list.rawValue
    @State private var newFolderSheet = false
    @State private var newFolderName = ""
    @State private var renameTarget: AdbEntry? = nil
    @State private var renameName: String = ""
    @State private var previewURL: URL? = nil
    @State private var storageSheet = false
    @State private var filterQuery: String = ""
    @State private var typeFilter: FileTypeFilter = .all
    @State private var dateFilter: FileDateFilter = .any
    @FocusState private var tableFocused: Bool

    private var viewMode: FilesViewMode {
        FilesViewMode(rawValue: viewModeRaw) ?? .list
    }

    private var visibleEntries: [AdbEntry] {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.entries.filter { entry in
            if !FileClassifier.matches(entry, type: typeFilter, date: dateFilter) {
                return false
            }
            if !q.isEmpty && !entry.name.lowercased().contains(q) {
                return false
            }
            return true
        }
    }

    private var selectedVisibleEntries: [AdbEntry] {
        visibleEntries.filter { model.selection.contains($0.id) }
    }

    private var downloadableSelection: [AdbEntry] {
        selectedVisibleEntries.filter { $0.kind == .file || $0.isDirectory }
    }

    private var hasActiveFilters: Bool {
        !filterQuery.isEmpty || typeFilter != .all || dateFilter != .any
    }

    private var inboxURL: URL {
        URL(fileURLWithPath: Preferences.shared.fileInboxPath, isDirectory: true)
    }

    private var inboxDisplayName: String {
        let name = inboxURL.lastPathComponent
        return name.isEmpty ? "Downloads" : name
    }

    private var currentDeviceLabel: String {
        if model.isProtocolMode {
            return model.activeWifiDevice?.name ?? state.pairedDeviceName ?? "Paired phone"
        }
        if let s = model.selectedSerial,
           let d = model.devices.first(where: { $0.serial == s }) {
            return d.model ?? d.serial
        }
        return model.devices.isEmpty ? "No device" : "Select a device"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            favoritesStrip
            Divider()
            navigationAndFilterBar
            Divider()

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            busyBar
            downloadSummaryBar
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(keyboardShortcuts)
        .task { await model.bootstrap() }
        .onChange(of: model.currentPath) { _, _ in
            filterQuery = ""
            typeFilter = .all
            dateFilter = .any
        }
        .onChange(of: filterQuery) { _, _ in pruneSelectionToVisible() }
        .onChange(of: typeFilter) { _, _ in pruneSelectionToVisible() }
        .onChange(of: dateFilter) { _, _ in pruneSelectionToVisible() }
        .onChange(of: state.activeDeviceId) { _, newId in
            guard let newId, model.isProtocolMode,
                  model.wifiDevices.contains(where: { $0.id == newId }),
                  model.selectedWifiDeviceId != newId else { return }
            model.selectedWifiDeviceId = newId
            model.goTo("/sdcard")
        }
        .sheet(isPresented: $newFolderSheet) { newFolderSheetBody }
        .sheet(item: $renameTarget) { entry in renameSheetBody(entry) }
        .sheet(isPresented: $storageSheet) {
            if let (backend, kind) = model.currentBackendSnapshot() {
                StorageAnalyzerView(
                    rootPath: model.currentPath,
                    backend: backend,
                    backendKind: kind
                ) { parent, name in
                    model.goTo(parent)
                    model.selection = [name]
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func pruneSelectionToVisible() {
        let visibleIDs = Set(visibleEntries.map(\.id))
        model.selection = model.selection.intersection(visibleIDs)
    }

    // MARK: - Header & Connection Pill

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phone Files").font(.largeTitle.weight(.semibold))
                HStack(spacing: 8) {
                    connectionMenuPill
                    if !diskString.isEmpty {
                        Text(diskString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)

            downloadMenu

            Button {
                storageSheet = true
            } label: {
                Label("Storage", systemImage: "chart.pie")
            }
            .help("Find what's eating space on the phone")
            .disabled(!model.canBrowse)

            Button {
                newFolderName = ""
                newFolderSheet = true
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.canBrowse)

            Button {
                pickAndUpload()
            } label: {
                Label("Upload…", systemImage: "arrow.up.doc")
            }
            .disabled(!model.canBrowse)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var connectionMenuPill: some View {
        Menu {
            if !model.wifiDevices.isEmpty {
                ForEach(model.wifiDevices) { dev in
                    Button {
                        model.selectWifiDevice(dev.id)
                    } label: {
                        let active = model.isProtocolMode && model.activeWifiDevice?.id == dev.id
                        Label(
                            "Wi-Fi • \(dev.name)",
                            systemImage: active ? "checkmark" : "wifi"
                        )
                    }
                }
            }
            if !model.devices.isEmpty {
                Divider()
                ForEach(model.devices) { device in
                    Button {
                        model.selectedSerial = device.serial
                        model.preferAdb = true
                        Task { await model.load() }
                    } label: {
                        let active = !model.isProtocolMode && model.selectedSerial == device.serial
                        Label(
                            "adb: \(device.label)",
                            systemImage: active ? "checkmark" : "cable.connector"
                        )
                    }
                }
            }
            Divider()
            Button {
                Task { await model.refreshDevices(tryAutoConnect: true) }
            } label: {
                Label("Refresh adb devices", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.isProtocolMode ? "wifi" : "cable.connector")
                    .font(.caption)
                    .foregroundStyle(model.canBrowse ? .green : .secondary)
                Text(model.canBrowse
                     ? "\(model.isProtocolMode ? (model.httpBulkAvailable ? "Wi-Fi Fast" : "Wi-Fi") : "adb") • \(currentDeviceLabel)"
                     : "Not connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch connected phones or Wi-Fi / adb mode")
    }

    // MARK: - Horizontal Favorites Strip (Single-Sidebar Design)

    private var favoritesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(defaultFileFavorites) { fav in
                    let active = model.currentPath == fav.path
                    Button {
                        model.openFavorite(fav)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: fav.symbol)
                                .font(.caption)
                                .foregroundStyle(active ? Color.white : Color.accentColor)
                            Text(fav.name)
                                .font(.callout.weight(active ? .medium : .regular))
                                .foregroundStyle(active ? Color.white : Color.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(active ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canBrowse)
                    .opacity(model.canBrowse ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Navigation, Smart Filters & View Switcher

    private var navigationAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                        .help("Back (⌘[)").accessibilityLabel("Back").disabled(!model.canGoBack)
                    Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                        .help("Forward (⌘])").accessibilityLabel("Forward").disabled(!model.canGoForward)
                    Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                        .help("Parent folder (⌘↑)").accessibilityLabel("Parent folder")
                        .disabled(!model.canGoUp || !model.canBrowse)
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload (⌘R)").accessibilityLabel("Reload folder").disabled(!model.canBrowse)
                }

                breadcrumb

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    TextField("Filter files…", text: $filterQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 130, idealWidth: 170, maxWidth: 210)
                        .disabled(!model.canBrowse)
                    if !filterQuery.isEmpty {
                        Button { filterQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear filter")
                        .accessibilityLabel("Clear file filter")
                    }
                }

                Picker("View mode", selection: Binding(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )) {
                    Image(systemName: "list.bullet").tag(FilesViewMode.list)
                        .help("List view")
                        .accessibilityLabel("List view")
                    Image(systemName: "square.grid.2x2").tag(FilesViewMode.grid)
                        .help("Thumbnail grid view")
                        .accessibilityLabel("Thumbnail grid view")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
            }

            // Smart type & date filter bar + bulk Select All helper
            HStack(spacing: 6) {
                ForEach(FileTypeFilter.allCases) { f in
                    filterPill(f.rawValue, active: typeFilter == f) { typeFilter = f }
                }
                Divider().frame(height: 14).padding(.horizontal, 2)
                ForEach(FileDateFilter.allCases) { d in
                    filterPill(d.rawValue, active: dateFilter == d) { dateFilter = d }
                }

                Spacer(minLength: 8)

                if !visibleEntries.isEmpty {
                    let allSelected = !visibleEntries.isEmpty
                        && visibleEntries.allSatisfy { model.selection.contains($0.id) }
                    Button(allSelected ? "Deselect all" : "Select all (\(visibleEntries.count))") {
                        if allSelected {
                            model.selection = []
                        } else {
                            model.selection = Set(visibleEntries.map(\.id))
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
    }

    private func filterPill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(active ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.canBrowse)
    }

    private var downloadButtonTitle: String {
        let n = downloadableSelection.count
        return n > 0 ? "Download (\(n))" : "Download"
    }

    @ViewBuilder
    private var downloadMenu: some View {
        let targets = downloadableSelection
        let disabled = !model.canBrowse || targets.isEmpty
        Menu {
            Button {
                downloadSelectionToInbox()
            } label: {
                Label("Save to \(inboxDisplayName) (⌘D)", systemImage: "arrow.down.circle")
            }
            Button {
                downloadSelectionToFolder()
            } label: {
                Label("Save to Folder… (⌘⇧D)", systemImage: "folder")
            }
            if targets.count == 1, let single = targets.first, single.kind == .file {
                Divider()
                Button {
                    savePull(single)
                } label: {
                    Label("Save As…", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            Label(downloadButtonTitle, systemImage: "arrow.down.doc")
        } primaryAction: {
            downloadSelectionToInbox()
        }
        .menuStyle(.borderedButton)
        .tint(disabled ? nil : .accentColor)
        .disabled(disabled)
        .help("Download selected files & folders to \(inboxDisplayName) (⌘D), or pick a folder (⌘⇧D)")
        .accessibilityLabel(targets.isEmpty
                            ? "Download selected items"
                            : "Download \(targets.count) selected items to \(inboxDisplayName)")
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
            Button("") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
            Button("") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command).disabled(!model.canGoUp)
            Button("") { Task { await model.load() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { downloadSelectionToInbox() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(downloadableSelection.isEmpty || !model.canBrowse)
            Button("") { downloadSelectionToFolder() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(downloadableSelection.isEmpty || !model.canBrowse)
            Button("") { triggerQuickLook() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { openSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { confirmDeleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { idx, part in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.goTo(part.1)
                    } label: {
                        Text(idx == 0 ? "Phone" : part.0)
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(idx == model.pathComponents.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: - Content Body (List vs Grid)

    @ViewBuilder
    private var contentBody: some View {
        if !model.canBrowse {
            noDevice
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.errorMessage, model.entries.isEmpty {
            errorView(err)
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("Drop files here to upload, or use the Upload button.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls: urls)
                return true
            }
        } else if visibleEntries.isEmpty {
            VStack(spacing: 10) {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("No files in this folder match the active filters.")
                )
                if hasActiveFilters {
                    Button("Reset filters") {
                        filterQuery = ""
                        typeFilter = .all
                        dateFilter = .any
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewMode == .grid {
            FilesGridView(
                entries: visibleEntries,
                currentPath: model.currentPath,
                deviceId: model.activeWifiDevice?.id,
                thumbnailsAvailable: model.thumbnailsAvailable,
                selection: $model.selection,
                onOpen: { openEntry($0) },
                onDropURLs: { handleDrop(urls: $0) },
                itemContextMenu: { ids in contextMenu(for: ids) }
            )
        } else {
            table
        }
    }

    private var table: some View {
        Table(visibleEntries,
              selection: $model.selection,
              sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                nameCell(entry)
            }
            .width(min: 180, ideal: 340)

            TableColumn("Size", value: \.size) { entry in
                Text(sizeText(for: entry))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            .width(min: 70, ideal: 90, max: 130)

            TableColumn("Date Modified", value: \.mtime) { entry in
                Text(Self.dateFormatter.string(from: entry.mtime))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .width(min: 120, ideal: 160, max: 220)
        }
        .focused($tableFocused)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            primaryAction(for: ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
            return true
        }
    }

    private func sizeText(for entry: AdbEntry) -> String {
        if !entry.isDirectory {
            return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        if let bytes = model.folderSizes[entry.name] {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return model.calculatingFolderSizes ? "…" : "—"
    }

    private func nameCell(_ entry: AdbEntry) -> some View {
        // Deliberately no `.onDrag` on Table rows — it breaks Table click/double-click on macOS.
        HStack(spacing: 8) {
            Image(systemName: FileClassifier.iconName(for: entry))
                .foregroundStyle(FileClassifier.iconColor(for: entry))
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let selected = visibleEntries.filter { ids.contains($0.id) }
        let downloadable = selected.filter { $0.kind == .file || $0.isDirectory }
        if selected.count == 1, let entry = selected.first {
            Button("Open") { openEntry(entry) }
            if entry.kind == .file {
                Button("Quick Look") {
                    Task { await previewEntry(entry) }
                }
            }
            if !downloadable.isEmpty {
                Divider()
                Button("Save to \(inboxDisplayName) (⌘D)") {
                    model.pullMany(downloadable, into: inboxURL)
                }
                if entry.kind == .file {
                    Button("Save As…") { savePull(entry) }
                } else {
                    Button("Save to Folder… (⌘⇧D)") {
                        pickFolderAndPull(downloadable)
                    }
                }
            }
            Divider()
            Button("Rename…") { startRename(entry) }
            Button(role: .destructive) {
                confirmDeleteEntries(selected)
            } label: {
                Text("Delete")
            }
        } else if selected.count > 1 {
            if !downloadable.isEmpty {
                Button("Save \(downloadable.count) items to \(inboxDisplayName) (⌘D)") {
                    model.pullMany(downloadable, into: inboxURL)
                }
                Button("Save \(downloadable.count) items to Folder… (⌘⇧D)") {
                    pickFolderAndPull(downloadable)
                }
                Divider()
            }
            Button(role: .destructive) {
                confirmDeleteEntries(selected)
            } label: {
                Text("Delete \(selected.count) items")
            }
        }
    }

    private func primaryAction(for ids: Set<String>) {
        if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
            openEntry(entry)
        }
    }

    // MARK: - Empty / Error / Status Bars

    private var noDevice: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No browsable phone storage")
                .font(.title3.weight(.semibold))
            Text("Grant \"All files access\" in NotifMirror on your paired phone to browse over Wi-Fi, or connect via USB / wireless adb for faster access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button {
                Task { await model.refreshDevices(tryAutoConnect: true) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Retry") { Task { await model.load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var busyBar: some View {
        if let msg = model.busyMessage {
            Divider()
            HStack(spacing: 10) {
                if let pct = model.busyProgress {
                    ProgressView(value: pct).frame(width: 140)
                    Text("\(Int(pct * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(msg).font(.callout).lineLimit(1)
                Spacer()
                if model.canCancelBusy {
                    Button("Cancel") { model.cancelActivePull() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 7)
        }
    }

    @ViewBuilder
    private var downloadSummaryBar: some View {
        if let summary = model.lastDownloadSummary, model.busyMessage == nil {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: summary.hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(summary.hasErrors ? .orange : .green)
                    .accessibilityHidden(true)
                Text(summary.message)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if !summary.revealURLs.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(summary.revealURLs)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    model.lastDownloadSummary = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss download summary")
            }
            .padding(.horizontal, 28).padding(.vertical, 7)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(itemCountString)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let err = model.errorMessage, !model.entries.isEmpty {
                Text("·").foregroundStyle(.tertiary).font(.caption)
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            if viewMode == .grid && !model.thumbnailsAvailable && model.canBrowse {
                Text("Update Android app for live photo thumbnails")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 6)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var itemCountString: String {
        let total = model.entries.count
        let visible = visibleEntries.count
        let sel = selectedVisibleEntries.count
        let base = visible == total ? "\(total) items" : "Showing \(visible) of \(total) items"
        if sel > 0 {
            return "\(base), \(sel) selected"
        }
        return base
    }

    private var diskString: String {
        guard let free = model.freeBytes, let total = model.totalBytes, total > 0 else {
            return ""
        }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: free)) free of \(f.string(fromByteCount: total))"
    }

    // MARK: - Actions

    private func openEntry(_ entry: AdbEntry) {
        if entry.isDirectory || entry.kind == .symlink {
            model.navigate(into: entry)
        } else if entry.kind == .file {
            Task { await model.openInDefaultApp(entry) }
        }
    }

    private func openSelected() {
        if let e = model.primarySelectedEntry { openEntry(e) }
    }

    private func triggerQuickLook() {
        guard let entry = model.primarySelectedEntry, entry.kind == .file else { return }
        Task { await previewEntry(entry) }
    }

    private func previewEntry(_ entry: AdbEntry) async {
        let url = await model.cachedLocalURL(for: entry)
        if let url { previewURL = url }
    }

    private func downloadSelectionToInbox() {
        let targets = downloadableSelection
        guard !targets.isEmpty else { return }
        model.pullMany(targets, into: inboxURL)
    }

    private func downloadSelectionToFolder() {
        let targets = downloadableSelection
        guard !targets.isEmpty else { return }
        pickFolderAndPull(targets)
    }

    private func pickFolderAndPull(_ targets: [AdbEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.directoryURL = inboxURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let folderURL = panel.url {
            model.pullMany(targets, into: folderURL)
        }
    }

    private func savePull(_ entry: AdbEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.directoryURL = inboxURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.pull(entry, to: url) }
        }
    }

    private func startRename(_ entry: AdbEntry) {
        renameName = entry.name
        renameTarget = entry
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await model.push(url) }
            }
        }
    }

    private func confirmDeleteSelection() {
        confirmDeleteEntries(selectedVisibleEntries)
    }

    private func confirmDeleteEntries(_ items: [AdbEntry]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        if items.count == 1 {
            let e = items[0]
            alert.messageText = "Delete \(e.name)?"
            alert.informativeText = e.isDirectory
                ? "This will remove the folder and all its contents on your phone."
                : "This will remove the file from your phone."
        } else {
            alert.messageText = "Delete \(items.count) items?"
            alert.informativeText = "This will remove the selected files and folders on your phone."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.deleteMany(items) }
        }
    }

    private func handleDrop(urls: [URL]) {
        guard !urls.isEmpty, model.canBrowse else { return }
        for url in urls {
            Task { await model.push(url) }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func renameSheetBody(_ entry: AdbEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(entry.name)”")
                .font(.headline)
            TextField("New name", text: $renameName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = renameName
                    renameTarget = nil
                    Task { await model.rename(entry, to: name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    renameName.trimmingCharacters(in: .whitespaces).isEmpty
                    || renameName == entry.name
                )
            }
        }
        .padding(18)
        .frame(minWidth: 360)
    }

    private var newFolderSheetBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New folder in \(model.currentPath)")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
            HStack {
                Spacer()
                Button("Cancel") { newFolderSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newFolderName
                    newFolderSheet = false
                    Task { await model.mkdir(name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
    }
}
