import AppKit
import SwiftUI

// MARK: - Favorites & Filters

struct FavoriteLocation: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let symbol: String
}

let defaultFileFavorites: [FavoriteLocation] = [
    .init(id: "sdcard",      name: "Storage",     path: "/sdcard",                       symbol: "externaldrive.fill"),
    .init(id: "dcim",        name: "Camera",      path: "/sdcard/DCIM/Camera",           symbol: "camera.fill"),
    .init(id: "screenshots", name: "Screenshots", path: "/sdcard/Pictures/Screenshots",  symbol: "rectangle.dashed"),
    .init(id: "download",    name: "Downloads",   path: "/sdcard/Download",              symbol: "arrow.down.circle.fill"),
    .init(id: "pictures",    name: "Pictures",    path: "/sdcard/Pictures",              symbol: "photo.on.rectangle"),
    .init(id: "movies",      name: "Movies",      path: "/sdcard/Movies",                symbol: "film.fill"),
    .init(id: "documents",   name: "Documents",   path: "/sdcard/Documents",             symbol: "doc.fill"),
    .init(id: "music",       name: "Music",       path: "/sdcard/Music",                 symbol: "music.note"),
]

enum FileTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case docs = "Docs"
    var id: String { rawValue }
}

enum FileDateFilter: String, CaseIterable, Identifiable {
    case any = "Any time"
    case today = "Today"
    case week = "7 days"
    var id: String { rawValue }
}

enum FilesViewMode: String, CaseIterable, Identifiable {
    case list
    case grid
    var id: String { rawValue }
}

enum FileClassifier {
    private static let photoExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng"]
    private static let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "3gp", "m4v"]
    private static let docExts: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "txt", "md", "rtf", "csv", "json", "xml", "log", "zip", "tar", "gz", "7z", "rar", "apk"
    ]

    static func ext(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func isPhoto(_ entry: AdbEntry) -> Bool {
        entry.kind == .file && photoExts.contains(ext(of: entry.name))
    }

    static func isVideo(_ entry: AdbEntry) -> Bool {
        entry.kind == .file && videoExts.contains(ext(of: entry.name))
    }

    static func isMedia(_ entry: AdbEntry) -> Bool {
        isPhoto(entry) || isVideo(entry)
    }

    static func isDocument(_ entry: AdbEntry) -> Bool {
        entry.kind == .file && docExts.contains(ext(of: entry.name))
    }

    static func matches(_ entry: AdbEntry, type: FileTypeFilter, date: FileDateFilter) -> Bool {
        if type != .all {
            if entry.isDirectory { return false }
            switch type {
            case .all: break
            case .photos: if !isPhoto(entry) { return false }
            case .videos: if !isVideo(entry) { return false }
            case .docs: if !isDocument(entry) { return false }
            }
        }
        switch date {
        case .any:
            return true
        case .today:
            return Calendar.current.isDateInToday(entry.mtime)
        case .week:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return true }
            return entry.mtime >= cutoff
        }
    }

    static func iconName(for entry: AdbEntry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink:   return "arrow.turn.up.right"
        case .file:      return fileIcon(for: entry.name)
        case .other:     return "questionmark.square"
        }
    }

    static func iconColor(for entry: AdbEntry) -> Color {
        switch entry.kind {
        case .directory: return .accentColor
        case .symlink:   return .orange
        case .file:      return .secondary
        case .other:     return .secondary
        }
    }

    private static func fileIcon(for name: String) -> String {
        switch ext(of: name) {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng":
            return "photo"
        case "mp4", "mkv", "mov", "avi", "webm", "3gp", "m4v":
            return "film"
        case "mp3", "m4a", "flac", "wav", "opus", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "xz", "7z", "rar":
            return "archivebox"
        case "txt", "md", "log":
            return "doc.text"
        case "apk":
            return "shippingbox"
        default:
            return "doc"
        }
    }
}

// MARK: - View model

@MainActor
final class FilesModel: ObservableObject {
    @Published var devices: [AdbDevice] = []
    @Published var selectedSerial: String? = nil
    @Published var selectedWifiDeviceId: String? = nil
    @Published var currentPath: String = "/sdcard"
    @Published var entries: [AdbEntry] = []
    @Published var selection: Set<String> = []
    @Published var isLoading: Bool = false
    @Published var busyMessage: String? = nil
    @Published var busyProgress: Double? = nil
    @Published var canCancelBusy: Bool = false
    @Published var lastDownloadSummary: DownloadSummary? = nil
    @Published var errorMessage: String? = nil
    @Published var freeBytes: Int64? = nil
    @Published var totalBytes: Int64? = nil

    struct DownloadSummary: Equatable {
        let message: String
        let revealURLs: [URL]
        let hasErrors: Bool
    }

    private var activePullTask: Task<Void, Never>? = nil
    private var activePushTask: Task<Void, Never>? = nil

    @Published var folderSizes: [String: Int64] = [:] {
        didSet { applySort() }
    }
    @Published var calculatingFolderSizes: Bool = false

    @Published var preferAdb: Bool = UserDefaults.standard.bool(forKey: "filesPreferAdb") {
        didSet {
            UserDefaults.standard.set(preferAdb, forKey: "filesPreferAdb")
            Task { await load() }
        }
    }

    @Published var sortOrder: [KeyPathComparator<AdbEntry>] = [
        KeyPathComparator(\.mtime, order: .reverse)
    ] {
        didSet { applySort() }
    }

    private var history: [String] = ["/sdcard"]
    private var historyIndex: Int = 0

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var canGoUp: Bool { currentPath != "/" }

    var selectedEntries: [AdbEntry] {
        entries.filter { selection.contains($0.id) }
    }
    var primarySelectedEntry: AdbEntry? { selectedEntries.first }

    // MARK: - Backend selection

    var wifiDevices: [ConnectedDevice] {
        AppState.shared.devices.filter { $0.features.contains("fsbrowse") }
    }

    var activeWifiDevice: ConnectedDevice? {
        if let id = selectedWifiDeviceId,
           let match = wifiDevices.first(where: { $0.id == id }) {
            return match
        }
        if let globalId = AppState.shared.activeDeviceId,
           let match = wifiDevices.first(where: { $0.id == globalId }) {
            return match
        }
        return wifiDevices.first
    }

    var fsbrowseAvailable: Bool {
        activeWifiDevice != nil
    }

    var thumbnailsAvailable: Bool {
        activeWifiDevice?.features.contains("fsthumb") == true
    }

    var httpBulkAvailable: Bool {
        isProtocolMode
            && BulkTransferServer.shared.port > 0
            && activeWifiDevice?.features.contains("httpbulk") == true
    }

    var isProtocolMode: Bool {
        guard fsbrowseAvailable else { return false }
        if preferAdb, !devices.isEmpty { return false }
        return true
    }

    private var backend: FileBackend? {
        if isProtocolMode, let dev = activeWifiDevice {
            return ProtocolFileBackend(deviceId: dev.id)
        }
        if let serial = selectedSerial { return AdbFileBackend(serial: serial) }
        return nil
    }

    var canBrowse: Bool { backend != nil }

    func selectWifiDevice(_ id: String) {
        selectedWifiDeviceId = id
        preferAdb = false
        AppState.shared.selectDevice(id)
        goTo("/sdcard")
    }

    func currentBackendSnapshot() -> (FileBackend, StorageAnalyzerModel.BackendKind)? {
        guard let backend else { return nil }
        return (backend, isProtocolMode ? .wifi : .adb)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        await refreshDevices(tryAutoConnect: true)
        if canBrowse {
            await load()
        }
    }

    func refreshDevices(tryAutoConnect: Bool = false) async {
        errorMessage = nil
        if tryAutoConnect, let host = AppState.shared.peerHost {
            await AdbClient.connectWireless(host: host)
        }
        do {
            let list = try await AdbClient.listDevices()
            self.devices = list
            if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = list.first?.serial
            }
        } catch {
            if !fsbrowseAvailable || preferAdb {
                errorMessage = Self.describe(error)
            }
            self.devices = []
        }
    }

    func load() async {
        guard let backend else { return }
        let requestedPath = currentPath
        isLoading = true
        errorMessage = nil
        entries = []
        defer { isLoading = false }

        let onBatch: @Sendable ([AdbEntry]) -> Void = { [weak self] batch in
            Task { @MainActor in
                guard let self, requestedPath == self.currentPath else { return }
                self.entries.append(contentsOf: batch)
                self.applySort()
            }
        }

        do {
            let list = try await backend.list(path: requestedPath, onBatch: onBatch)
            guard requestedPath == currentPath else { return }
            if self.entries.count != list.count {
                self.entries = list
                applySort()
            }
            selection = []
        } catch {
            guard requestedPath == currentPath else { return }
            entries = []
            errorMessage = Self.describe(error)
        }
        if requestedPath == currentPath {
            await refreshDiskUsage()
            Task { await self.calculateFolderSizes(for: requestedPath) }
        }
    }

    private func calculateFolderSizes(for path: String) async {
        guard let backend, path == currentPath else { return }
        calculatingFolderSizes = true
        defer {
            if path == currentPath { calculatingFolderSizes = false }
        }
        do {
            let report = try await backend.diskAnalyze(path: path)
            guard path == currentPath else { return }
            var sizes: [String: Int64] = [:]
            for e in report.entries where e.kind == .dir {
                sizes[e.name] = e.totalSize
            }
            folderSizes = sizes
        } catch {
            // Non-fatal — folders keep showing "—".
        }
    }

    private func refreshDiskUsage() async {
        guard let backend else {
            freeBytes = nil; totalBytes = nil
            return
        }
        if let usage = try? await backend.diskUsage(path: currentPath) {
            freeBytes = usage.free
            totalBytes = usage.total
        }
    }

    func applySort() {
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in sortOrder {
                if comparator.keyPath == \AdbEntry.size {
                    let sa = effectiveSize(a)
                    let sb = effectiveSize(b)
                    if sa != sb {
                        let ascending = comparator.order == .forward
                        return ascending ? sa < sb : sa > sb
                    }
                    continue
                }
                let result = comparator.compare(a, b)
                if result != .orderedSame {
                    return result == .orderedAscending
                }
            }
            return false
        }
    }

    private func effectiveSize(_ e: AdbEntry) -> Int64 {
        if e.isDirectory { return folderSizes[e.name] ?? 0 }
        return e.size
    }

    // MARK: - Navigation

    func navigate(into entry: AdbEntry) {
        guard entry.isDirectory || entry.kind == .symlink else { return }
        goTo(joinPath(currentPath, entry.name))
    }

    func goUp() {
        guard canGoUp else { return }
        var parent = currentPath
        if parent.hasSuffix("/") { parent.removeLast() }
        if let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
        }
        if parent.isEmpty { parent = "/" }
        goTo(parent)
    }

    func goTo(_ path: String) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != path { history.append(path) }
        historyIndex = history.count - 1
        currentPath = path
        clearForNavigation()
        Task { await load() }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = history[historyIndex]
        clearForNavigation()
        Task { await load() }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = history[historyIndex]
        clearForNavigation()
        Task { await load() }
    }

    private func clearForNavigation() {
        entries = []
        selection = []
        errorMessage = nil
        isLoading = true
        folderSizes = [:]
        calculatingFolderSizes = false
    }

    // MARK: - File ops (connected to Unified Transfer Queue)

    private func pullWithFallback(
        remote: String,
        to localURL: URL,
        entryName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let backend else {
            throw ProtocolFileClient.FsError(message: "No backend available")
        }

        let progress: (@Sendable (Double) -> Void) = onProgress ?? { pct in
            Task { @MainActor in self.busyProgress = pct }
        }

        do {
            try await backend.pull(remote: remote, to: localURL, onProgress: progress)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let serial = selectedSerial
            let hadAdbDevice = !devices.isEmpty && serial != nil
            guard isProtocolMode, hadAdbDevice, let serial else {
                await refreshDevices(tryAutoConnect: true)
                if Task.isCancelled { throw CancellationError() }
                if !devices.isEmpty, let rescuedSerial = selectedSerial {
                    busyMessage = "Wi-Fi stalled — retrying \(entryName) over adb…"
                    try? FileManager.default.removeItem(at: localURL)
                    try await AdbFileBackend(serial: rescuedSerial).pull(
                        remote: remote, to: localURL, onProgress: progress
                    )
                    return
                }
                throw error
            }
            busyMessage = "Wi-Fi stalled — retrying \(entryName) over adb…"
            try? FileManager.default.removeItem(at: localURL)
            try await AdbFileBackend(serial: serial).pull(
                remote: remote, to: localURL, onProgress: progress
            )
        }
    }

    func cancelActivePull() {
        activePullTask?.cancel()
        activePullTask = nil
        activePushTask?.cancel()
        activePushTask = nil
    }

    func pull(_ entry: AdbEntry, to destination: URL) async {
        guard backend != nil else { return }
        let remote = joinPath(currentPath, entry.name)
        let dev = activeWifiDevice
        lastDownloadSummary = nil
        let transferId = FileTransferCenter.shared.beginExternalTransfer(
            direction: .incoming,
            name: entry.name,
            size: max(0, entry.size),
            deviceId: dev?.id,
            deviceName: dev?.name,
            destinationPath: destination.path,
            onCancel: { [weak self] in self?.cancelActivePull() }
        )

        let task = Task { @MainActor in
            self.canCancelBusy = true
            defer {
                self.canCancelBusy = false
                self.activePullTask = nil
            }
            var succeeded = false
            await self.withBusy("Downloading \(entry.name)…") {
                try await self.pullWithFallback(
                    remote: remote,
                    to: destination,
                    entryName: entry.name,
                    onProgress: { pct in
                        Task { @MainActor in
                            self.busyProgress = pct
                            let doneBytes = Int64(Double(max(0, entry.size)) * pct)
                            FileTransferCenter.shared.updateExternalTransfer(
                                id: transferId, bytesTransferred: doneBytes
                            )
                        }
                    }
                )
                succeeded = true
            }
            if Task.isCancelled {
                FileTransferCenter.shared.finishExternalTransfer(id: transferId, status: .cancelled)
            } else if succeeded {
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId, status: .done, destinationPath: destination.path
                )
                self.lastDownloadSummary = DownloadSummary(
                    message: "Saved \(entry.name)",
                    revealURLs: [destination],
                    hasErrors: false
                )
            } else {
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId, status: .failed(self.errorMessage ?? "download failed")
                )
            }
        }
        activePullTask = task
        await task.value
    }

    func pullMany(_ selected: [AdbEntry], into destinationDir: URL) {
        guard !selected.isEmpty, let activeBackend = backend else { return }
        let baseRemote = currentPath
        let dev = activeWifiDevice
        let useParallel = httpBulkAvailable
        activePullTask?.cancel()
        lastDownloadSummary = nil

        let initialTitle = selected.count == 1
            ? selected[0].name
            : "\(selected.count) items from \(URL(fileURLWithPath: baseRemote).lastPathComponent)"
        let transferId = FileTransferCenter.shared.beginExternalTransfer(
            direction: .incoming,
            name: initialTitle,
            size: 0,
            deviceId: dev?.id,
            deviceName: dev?.name,
            destinationPath: destinationDir.path,
            itemCount: selected.count,
            onCancel: { [weak self] in self?.cancelActivePull() }
        )

        let task = Task { @MainActor in
            self.canCancelBusy = true
            self.busyMessage = "Preparing download…"
            self.busyProgress = nil
            self.errorMessage = nil
            defer {
                self.busyMessage = nil
                self.busyProgress = nil
                self.canCancelBusy = false
                self.activePullTask = nil
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            struct PlannedFile: Sendable {
                let index: Int
                let remotePath: String
                let localURL: URL
                let displayName: String
                let size: Int64
            }

            var plannedFiles: [PlannedFile] = []
            var plannedDirs: [URL] = []
            var topLevelURLs: [URL] = []
            var failures: [(String, String)] = []

            @MainActor
            func walkDirectory(remoteDir: String, localDir: URL, depth: Int) async {
                guard depth < 32, !Task.isCancelled else { return }
                plannedDirs.append(localDir)
                do {
                    let children = try await activeBackend.list(path: remoteDir)
                    for child in children {
                        if Task.isCancelled { return }
                        let childRemote = self.joinPath(remoteDir, child.name)
                        let childLocal = localDir.appendingPathComponent(child.name)
                        if child.isDirectory {
                            await walkDirectory(remoteDir: childRemote, localDir: childLocal, depth: depth + 1)
                        } else if child.kind == .file {
                            plannedFiles.append(PlannedFile(
                                index: plannedFiles.count,
                                remotePath: childRemote,
                                localURL: childLocal,
                                displayName: child.name,
                                size: child.size
                            ))
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures.append((remoteDir, Self.describe(error)))
                }
            }

            for entry in selected {
                if Task.isCancelled { break }
                let remote = self.joinPath(baseRemote, entry.name)
                let targetURL = Self.uniqueDestination(in: destinationDir, name: entry.name)
                topLevelURLs.append(targetURL)
                if entry.isDirectory {
                    self.busyMessage = "Scanning folder \(entry.name)…"
                    await walkDirectory(remoteDir: remote, localDir: targetURL, depth: 0)
                } else if entry.kind == .file {
                    plannedFiles.append(PlannedFile(
                        index: plannedFiles.count,
                        remotePath: remote,
                        localURL: targetURL,
                        displayName: entry.name,
                        size: entry.size
                    ))
                }
            }

            if Task.isCancelled {
                self.errorMessage = "Download cancelled."
                FileTransferCenter.shared.finishExternalTransfer(id: transferId, status: .cancelled)
                return
            }

            for dir in plannedDirs {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let totalFiles = plannedFiles.count
            let totalBytes = plannedFiles.reduce(Int64(0)) { $0 + max(0, $1.size) }
            let batchLabel = totalFiles == 1 && plannedDirs.isEmpty
                ? (plannedFiles.first?.displayName ?? initialTitle)
                : "\(initialTitle) (\(totalFiles) files)"
            FileTransferCenter.shared.updateExternalTransfer(
                id: transferId,
                bytesTransferred: 0,
                totalSize: max(totalBytes, 1),
                name: batchLabel,
                destinationPath: topLevelURLs.first?.path ?? destinationDir.path
            )
            AppState.shared.transfers[transferId]?.itemCount = max(totalFiles, 1)

            var perFileBytes: [Int: Int64] = [:]
            var succeededFiles = 0
            let startedAt = CFAbsoluteTimeGetCurrent()

            @MainActor
            func refreshAggregateProgress(label: String? = nil) {
                let doneBytes = perFileBytes.values.reduce(Int64(0), +)
                if totalBytes > 0 {
                    self.busyProgress = min(1.0, Double(doneBytes) / Double(totalBytes))
                    FileTransferCenter.shared.updateExternalTransfer(
                        id: transferId, bytesTransferred: doneBytes
                    )
                } else if totalFiles > 0 {
                    self.busyProgress = min(1.0, Double(succeededFiles) / Double(totalFiles))
                }
                if let label {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                    if elapsed > 0.4, doneBytes > 64 * 1024 {
                        let bps = Int64(Double(doneBytes) / elapsed)
                        let rate = ByteCountFormatter.string(fromByteCount: bps, countStyle: .file)
                        self.busyMessage = "\(label) • \(rate)/s"
                    } else {
                        self.busyMessage = label
                    }
                }
            }

            if useParallel && totalFiles > 1 {
                // Stream up to 3 files concurrently over TLS HTTP/1.1 to eliminate
                // per-file handshake latency on photo/camera batches.
                let concurrency = 3
                var nextIndex = 0

                await withTaskGroup(of: (PlannedFile, Error?).self) { group in
                    func enqueueNext() {
                        guard nextIndex < plannedFiles.count, !Task.isCancelled else { return }
                        let item = plannedFiles[nextIndex]
                        nextIndex += 1
                        let parent = item.localURL.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        let fileSize = max(0, item.size)
                        group.addTask {
                            do {
                                try await activeBackend.pull(
                                    remote: item.remotePath,
                                    to: item.localURL,
                                    onProgress: { pct in
                                        Task { @MainActor in
                                            perFileBytes[item.index] = Int64(Double(fileSize) * pct)
                                            refreshAggregateProgress(
                                                label: "Downloading \(succeededFiles + 1) of \(totalFiles) — \(item.displayName)"
                                            )
                                        }
                                    }
                                )
                                return (item, nil)
                            } catch {
                                return (item, error)
                            }
                        }
                    }

                    for _ in 0..<min(concurrency, plannedFiles.count) { enqueueNext() }

                    for await (item, err) in group {
                        if let err {
                            try? fm.removeItem(at: item.localURL)
                            if !(err is CancellationError) && !Task.isCancelled {
                                failures.append((item.displayName, Self.describe(err)))
                            }
                        } else {
                            succeededFiles += 1
                            perFileBytes[item.index] = max(0, item.size)
                            refreshAggregateProgress(
                                label: "Downloading \(min(succeededFiles + 1, totalFiles)) of \(totalFiles)"
                            )
                        }
                        if Task.isCancelled {
                            group.cancelAll()
                        } else {
                            enqueueNext()
                        }
                    }
                }
            } else {
                for (idx, item) in plannedFiles.enumerated() {
                    if Task.isCancelled { break }
                    let parent = item.localURL.deletingLastPathComponent()
                    try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    let stepLabel = totalFiles > 1
                        ? "Downloading \(idx + 1) of \(totalFiles) — \(item.displayName)"
                        : "Downloading \(item.displayName)…"
                    refreshAggregateProgress(label: stepLabel)

                    let fileSize = max(0, item.size)
                    do {
                        try await self.pullWithFallback(
                            remote: item.remotePath,
                            to: item.localURL,
                            entryName: item.displayName,
                            onProgress: { pct in
                                Task { @MainActor in
                                    perFileBytes[item.index] = Int64(Double(fileSize) * pct)
                                    refreshAggregateProgress(label: stepLabel)
                                }
                            }
                        )
                        succeededFiles += 1
                        perFileBytes[item.index] = fileSize
                        refreshAggregateProgress(label: stepLabel)
                    } catch is CancellationError {
                        try? fm.removeItem(at: item.localURL)
                        break
                    } catch {
                        try? fm.removeItem(at: item.localURL)
                        failures.append((item.displayName, Self.describe(error)))
                    }
                }
            }

            let existingTargets = topLevelURLs.filter { fm.fileExists(atPath: $0.path) }
            let revealTarget = existingTargets.first?.path ?? destinationDir.path
            let folderLabel = destinationDir.lastPathComponent
            if Task.isCancelled {
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId, status: .cancelled, destinationPath: revealTarget
                )
                if succeededFiles > 0 {
                    self.lastDownloadSummary = DownloadSummary(
                        message: "Cancelled after saving \(succeededFiles) of \(totalFiles) files to \(folderLabel)",
                        revealURLs: existingTargets,
                        hasErrors: true
                    )
                } else {
                    self.errorMessage = "Download cancelled."
                }
            } else if failures.isEmpty {
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId, status: .done, destinationPath: revealTarget
                )
                let countLabel = totalFiles == 1 && plannedDirs.isEmpty
                    ? (plannedFiles.first?.displayName ?? "1 item")
                    : "\(totalFiles) file\(totalFiles == 1 ? "" : "s")"
                let elapsed = max(0.05, CFAbsoluteTimeGetCurrent() - startedAt)
                let speedPart: String
                if totalBytes > 128 * 1024 {
                    let rate = ByteCountFormatter.string(
                        fromByteCount: Int64(Double(totalBytes) / elapsed),
                        countStyle: .file
                    )
                    speedPart = " (\(rate)/s)"
                } else {
                    speedPart = ""
                }
                self.lastDownloadSummary = DownloadSummary(
                    message: "Saved \(countLabel) to \(folderLabel)\(speedPart)",
                    revealURLs: existingTargets,
                    hasErrors: false
                )
            } else {
                let firstErr = failures.first.map { "\($0.0): \($0.1)" } ?? ""
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId,
                    status: .failed("\(failures.count) failed — \(firstErr)"),
                    destinationPath: revealTarget
                )
                self.lastDownloadSummary = DownloadSummary(
                    message: "Saved \(succeededFiles) of \(totalFiles) files (\(failures.count) failed — \(firstErr))",
                    revealURLs: existingTargets,
                    hasErrors: true
                )
            }
        }
        activePullTask = task
    }

    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 1...999 {
            let next = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return candidate
    }

    func openInDefaultApp(_ entry: AdbEntry) async {
        guard let url = await cachedLocalURL(for: entry) else { return }
        NSWorkspace.shared.open(url)
    }

    func cachedLocalURL(for entry: AdbEntry) async -> URL? {
        guard backend != nil, entry.kind == .file else { return nil }
        let cacheDir = Self.previewCacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let localURL = cacheDir.appendingPathComponent(entry.name)
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
           let localSize = attrs[.size] as? Int64,
           localSize == entry.size,
           let localMTime = attrs[.modificationDate] as? Date,
           localMTime >= entry.mtime {
            return localURL
        }

        try? fm.removeItem(at: localURL)
        let remote = joinPath(currentPath, entry.name)
        var ok = false
        await withBusy("Downloading \(entry.name)…") {
            try await self.pullWithFallback(
                remote: remote, to: localURL, entryName: entry.name
            )
            ok = true
        }
        return (ok && fm.fileExists(atPath: localURL.path)) ? localURL : nil
    }

    private static let previewCacheDir: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifMirror-preview", isDirectory: true)
    }()

    func push(_ localURL: URL) async {
        guard let backend else { return }
        let dev = activeWifiDevice
        let attrs = (try? FileManager.default.attributesOfItem(atPath: localURL.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let transferId = FileTransferCenter.shared.beginExternalTransfer(
            direction: .outgoing,
            name: localURL.lastPathComponent,
            size: fileSize,
            deviceId: dev?.id,
            deviceName: dev?.name,
            onCancel: { [weak self] in self?.cancelActivePull() }
        )
        let remotePath = isProtocolMode
            ? joinPath(currentPath, localURL.lastPathComponent)
            : currentPath

        let task = Task { @MainActor in
            self.canCancelBusy = true
            defer {
                self.canCancelBusy = false
                self.activePushTask = nil
            }
            var succeeded = false
            await self.withBusy("Uploading \(localURL.lastPathComponent)…") {
                try await backend.push(
                    local: localURL,
                    to: remotePath,
                    onProgress: { pct in
                        Task { @MainActor in
                            self.busyProgress = pct
                            FileTransferCenter.shared.updateExternalTransfer(
                                id: transferId,
                                bytesTransferred: Int64(Double(fileSize) * pct)
                            )
                        }
                    }
                )
                succeeded = true
            }
            if Task.isCancelled {
                FileTransferCenter.shared.finishExternalTransfer(id: transferId, status: .cancelled)
            } else if succeeded {
                FileTransferCenter.shared.finishExternalTransfer(id: transferId, status: .done)
            } else {
                FileTransferCenter.shared.finishExternalTransfer(
                    id: transferId, status: .failed(self.errorMessage ?? "upload failed")
                )
            }
            await self.load()
        }
        activePushTask = task
        await task.value
    }

    func delete(_ entry: AdbEntry) async {
        guard let backend else { return }
        await withBusy("Deleting \(entry.name)…") {
            try await backend.delete(path: self.joinPath(self.currentPath, entry.name))
        }
        await load()
    }

    func deleteMany(_ entries: [AdbEntry]) async {
        guard !entries.isEmpty else { return }
        for e in entries { await delete(e) }
    }

    func mkdir(_ name: String) async {
        guard let backend else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        await withBusy("Creating folder…") {
            try await backend.mkdir(path: self.joinPath(self.currentPath, cleaned))
        }
        await load()
    }

    func rename(_ entry: AdbEntry, to newName: String) async {
        guard let backend else { return }
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != entry.name else { return }
        if cleaned.contains("/") {
            errorMessage = "Name cannot contain “/”"
            return
        }
        let from = joinPath(currentPath, entry.name)
        let to = joinPath(currentPath, cleaned)
        await withBusy("Renaming \(entry.name)…") {
            try await backend.rename(from: from, to: to)
        }
        await load()
        if errorMessage == nil {
            selection = [cleaned]
        }
    }

    // MARK: - Helpers

    private func withBusy(_ message: String, _ work: () async throws -> Void) async {
        busyMessage = message
        busyProgress = nil
        errorMessage = nil
        defer {
            busyMessage = nil
            busyProgress = nil
        }
        do {
            try await work()
        } catch is CancellationError {
            errorMessage = "Download cancelled."
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func joinPath(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        return "\(base)/\(name)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    var pathComponents: [(String, String)] {
        var acc: [(String, String)] = [("/", "/")]
        var running = ""
        for part in currentPath.split(separator: "/") {
            running += "/\(part)"
            acc.append((String(part), running))
        }
        return acc
    }

    func openFavorite(_ fav: FavoriteLocation) {
        guard canBrowse else { return }
        goTo(fav.path)
    }
}
