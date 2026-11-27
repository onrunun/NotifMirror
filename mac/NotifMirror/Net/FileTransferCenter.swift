import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Coordinates direct two-way file transfers across multiple connected phones
/// using `BulkTransferServer` (TLS HTTP/1.1 streaming) when available, with
/// automatic WebSocket binary fallback for older peers.
@MainActor
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private let chunkSize = 256 * 1024
    private static let legacyWriteQueue = DispatchQueue(
        label: "com.notifmirror.app.fileChunkWrite",
        qos: .userInitiated
    )
    private nonisolated(unsafe) static var legacyIncomingHandles: [String: FileHandle] = [:]

    private var incoming: [String: IncomingState] = [:]
    private var outgoing: [String: OutgoingState] = [:]
    private var externalCancelHandlers: [String: () -> Void] = [:]

    private struct IncomingState {
        let deviceId: String
        let url: URL
        let handle: FileHandle?
        let expectedSize: Int64
        var received: Int64
        let expectedSha256: String?
        let usesBulkHttp: Bool
    }

    private struct OutgoingState {
        let deviceId: String
        let url: URL
        let size: Int64
        var offset: Int64
        let usesBulkHttp: Bool
    }

    private init() {}

    // MARK: - Outgoing (Mac → Android)

    func sendFile(url: URL, to explicitDeviceId: String? = nil) {
        guard let targetDevice = AppState.shared.device(id: explicitDeviceId) else {
            AppState.shared.lastError = "No paired device is connected."
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            AppState.shared.lastError = "Not a regular file."
            return
        }
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let xid = Self.newXid()
        let useBulk = BulkTransferServer.shared.port > 0 && targetDevice.features.contains("httpbulk")
        outgoing[xid] = OutgoingState(
            deviceId: targetDevice.id,
            url: url,
            size: size,
            offset: 0,
            usesBulkHttp: useBulk
        )
        AppState.shared.transfers[xid] = TransferProgress(
            id: xid,
            direction: .outgoing,
            deviceId: targetDevice.id,
            deviceName: targetDevice.name,
            name: url.lastPathComponent,
            size: size,
            bytesTransferred: 0,
            status: .pending,
            sourceURL: url,
            startedAt: Date()
        )

        if useBulk {
            BulkTransferServer.shared.registerDownload(
                id: xid,
                source: url,
                onProgress: { sent, _ in
                    Task { @MainActor in
                        AppState.shared.transfers[xid]?.bytesTransferred = sent
                    }
                },
                onComplete: { result in
                    if case let .failure(err) = result {
                        Task { @MainActor in
                            if let cur = AppState.shared.transfers[xid], cur.isInFlight {
                                AppState.shared.transfers[xid]?.status = .failed(err.localizedDescription)
                            }
                            FileTransferCenter.shared.outgoing.removeValue(forKey: xid)
                        }
                    }
                }
            )
        }

        let mime = Self.mimeType(for: url)
        WsServer.shared.send(.fileOffer(.init(
            xid: xid,
            name: url.lastPathComponent,
            size: size,
            mime: mime,
            sha256: nil
        )), to: targetDevice.id)
    }

    func handleAccept(xid: String) {
        guard var s = outgoing[xid] else { return }
        AppState.shared.transfers[xid]?.status = .active
        if s.usesBulkHttp {
            // Android pulls bytes straight from `BulkTransferServer` via GET /download/<xid>.
            return
        }
        pump(xid: xid, state: &s)
    }

    func handleReject(xid: String, reason: String) {
        if let s = outgoing.removeValue(forKey: xid), s.usesBulkHttp {
            BulkTransferServer.shared.cancel(id: xid)
        }
        AppState.shared.transfers[xid]?.status = .failed("rejected: \(reason)")
    }

    func handleAck(xid: String, ok: Bool, error: String?) {
        outgoing.removeValue(forKey: xid)
        if ok {
            if let total = AppState.shared.transfers[xid]?.size, total > 0 {
                AppState.shared.transfers[xid]?.bytesTransferred = total
            }
            AppState.shared.transfers[xid]?.status = .done
        } else {
            AppState.shared.transfers[xid]?.status = .failed(error ?? "unknown")
        }
    }

    private struct PumpJob: Sendable {
        let xid: String
        let deviceId: String
        let url: URL
        let size: Int64
        let chunk: Int
    }

    private func pump(xid: String, state: inout OutgoingState) {
        outgoing[xid] = state
        let job = PumpJob(xid: xid, deviceId: state.deviceId, url: state.url, size: state.size, chunk: chunkSize)
        Task.detached { [weak self] in
            await Self.pumpOffMain(job: job, center: self)
        }
    }

    private static func pumpOffMain(job: PumpJob, center: FileTransferCenter?) async {
        let xid = job.xid
        let deviceId = job.deviceId
        let url = job.url
        let size = job.size
        let chunk = job.chunk
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            await MainActor.run {
                WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"), to: deviceId)
                AppState.shared.transfers[xid]?.status = .failed("open: \(error.localizedDescription)")
                center?.outgoing.removeValue(forKey: xid)
            }
            return
        }
        defer { try? fh.close() }

        var offset: Int64 = 0
        while true {
            let shouldContinue: Bool = await MainActor.run {
                guard let c = center, c.outgoing[xid] != nil else { return false }
                guard case .active = AppState.shared.transfers[xid]?.status else { return false }
                return true
            }
            if !shouldContinue { return }

            let remaining = size - offset
            if remaining <= 0 {
                await MainActor.run {
                    WsServer.shared.send(.fileDone(xid: xid), to: deviceId)
                }
                return
            }

            let toRead = Int(min(Int64(chunk), remaining))
            let data: Data
            do {
                try fh.seek(toOffset: UInt64(offset))
                data = try fh.read(upToCount: toRead) ?? Data()
            } catch {
                await MainActor.run {
                    WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"), to: deviceId)
                    AppState.shared.transfers[xid]?.status = .failed("read: \(error.localizedDescription)")
                    center?.outgoing.removeValue(forKey: xid)
                }
                return
            }
            if data.isEmpty { return }

            let last = (offset + Int64(data.count)) >= size
            let sentOffset = offset
            offset += Int64(data.count)

            await withCheckedContinuation { (sentCont: CheckedContinuation<Void, Never>) in
                WsServer.shared.sendBinaryChunk(
                    kind: WsServer.chunkKindFile,
                    id: xid,
                    offset: sentOffset,
                    payload: data,
                    last: last,
                    to: deviceId
                ) { _ in sentCont.resume() }
            }

            await MainActor.run {
                if var s = center?.outgoing[xid] {
                    s.offset = offset
                    center?.outgoing[xid] = s
                }
                AppState.shared.transfers[xid]?.bytesTransferred = offset
                if last {
                    WsServer.shared.send(.fileDone(xid: xid), to: deviceId)
                }
            }

            if last { return }
        }
    }

    // MARK: - Incoming (Android → Mac)

    func handleOffer(_ offer: WireMessage.FileOffer, from deviceId: String, deviceName: String) {
        let inbox = Preferences.shared.fileInboxPath
        let dir = URL(fileURLWithPath: inbox, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            WsServer.shared.send(.fileReject(xid: offer.xid, reason: "io_error"), to: deviceId)
            AppState.shared.lastError = "Inbox create failed: \(error.localizedDescription)"
            return
        }

        let dest = Self.uniqueDestination(in: dir, name: offer.name)
        let peerHasBulk = AppState.shared.device(id: deviceId)?.features.contains("httpbulk") == true
        let useBulk = BulkTransferServer.shared.port > 0 && peerHasBulk && offer.size >= 0

        if useBulk {
            incoming[offer.xid] = IncomingState(
                deviceId: deviceId,
                url: dest,
                handle: nil,
                expectedSize: offer.size,
                received: 0,
                expectedSha256: offer.sha256,
                usesBulkHttp: true
            )
            AppState.shared.transfers[offer.xid] = TransferProgress(
                id: offer.xid,
                direction: .incoming,
                deviceId: deviceId,
                deviceName: deviceName,
                name: dest.lastPathComponent,
                size: offer.size,
                bytesTransferred: 0,
                status: .active,
                destinationPath: dest.path
            )
            BulkTransferServer.shared.registerUpload(
                id: offer.xid,
                destination: dest,
                expectedSize: offer.size,
                onProgress: { bytes, _ in
                    Task { @MainActor in
                        AppState.shared.transfers[offer.xid]?.bytesTransferred = bytes
                    }
                },
                onComplete: { result in
                    Task { @MainActor in
                        FileTransferCenter.shared.finishBulkIncoming(xid: offer.xid, result: result)
                    }
                }
            )
            WsServer.shared.send(.fileAccept(xid: offer.xid), to: deviceId)
            return
        }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            WsServer.shared.send(.fileReject(xid: offer.xid, reason: "io_error"), to: deviceId)
            return
        }

        incoming[offer.xid] = IncomingState(
            deviceId: deviceId,
            url: dest,
            handle: handle,
            expectedSize: offer.size,
            received: 0,
            expectedSha256: offer.sha256,
            usesBulkHttp: false
        )
        Self.legacyWriteQueue.async { Self.legacyIncomingHandles[offer.xid] = handle }

        AppState.shared.transfers[offer.xid] = TransferProgress(
            id: offer.xid,
            direction: .incoming,
            deviceId: deviceId,
            deviceName: deviceName,
            name: dest.lastPathComponent,
            size: offer.size,
            bytesTransferred: 0,
            status: .active,
            destinationPath: dest.path
        )

        WsServer.shared.send(.fileAccept(xid: offer.xid), to: deviceId)
    }

    private func finishBulkIncoming(xid: String, result: Result<Int64, Error>) {
        guard let s = incoming.removeValue(forKey: xid) else { return }
        switch result {
        case let .success(written):
            if s.expectedSize > 0 && written != s.expectedSize {
                AppState.shared.transfers[xid]?.status = .failed(
                    "size mismatch (got \(written), expected \(s.expectedSize))"
                )
                WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "size_mismatch"), to: s.deviceId)
                return
            }
            if let expected = s.expectedSha256, let actual = Self.sha256(of: s.url), actual != expected {
                AppState.shared.transfers[xid]?.status = .failed("sha256 mismatch")
                WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "sha256_mismatch"), to: s.deviceId)
                return
            }
            AppState.shared.transfers[xid]?.bytesTransferred = written
            AppState.shared.transfers[xid]?.status = .done
            WsServer.shared.send(.fileAck(xid: xid, ok: true, error: nil), to: s.deviceId)
            notifyArrived(name: s.url.lastPathComponent, path: s.url.path)
        case let .failure(err):
            if err is CancellationError {
                AppState.shared.transfers[xid]?.status = .cancelled
            } else {
                AppState.shared.transfers[xid]?.status = .failed(err.localizedDescription)
                WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "io_error"), to: s.deviceId)
            }
        }
    }

    /// Legacy WS binary chunk receiver — writes directly on `legacyWriteQueue`.
    nonisolated func handleBinaryChunk(xid: String, offset: Int64, bytes: Data, last: Bool) {
        Self.legacyWriteQueue.async {
            guard let handle = Self.legacyIncomingHandles[xid] else { return }
            do {
                if !bytes.isEmpty {
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: bytes)
                    let received = offset + Int64(bytes.count)
                    Task { @MainActor in
                        if var s = FileTransferCenter.shared.incoming[xid] {
                            s.received = received
                            FileTransferCenter.shared.incoming[xid] = s
                        }
                        AppState.shared.transfers[xid]?.bytesTransferred = received
                    }
                }
                _ = last
            } catch {
                Task { @MainActor in
                    FileTransferCenter.shared.failIncoming(xid: xid, msg: "write: \(error.localizedDescription)")
                }
            }
        }
    }

    func handleDone(xid: String) {
        guard let s = incoming.removeValue(forKey: xid) else {
            WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "unknown xid"))
            return
        }
        Self.legacyWriteQueue.async {
            if let h = Self.legacyIncomingHandles.removeValue(forKey: xid) { try? h.close() }
        }
        do { try s.handle?.close() } catch { /* ignore */ }

        if s.received != s.expectedSize {
            AppState.shared.transfers[xid]?.status = .failed(
                "size mismatch (got \(s.received), expected \(s.expectedSize))"
            )
            WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "size_mismatch"), to: s.deviceId)
            return
        }

        if let expected = s.expectedSha256 {
            if let actual = Self.sha256(of: s.url), actual != expected {
                AppState.shared.transfers[xid]?.status = .failed("sha256 mismatch")
                WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "sha256_mismatch"), to: s.deviceId)
                return
            }
        }

        AppState.shared.transfers[xid]?.status = .done
        WsServer.shared.send(.fileAck(xid: xid, ok: true, error: nil), to: s.deviceId)
        notifyArrived(name: s.url.lastPathComponent, path: s.url.path)
    }

    private func notifyArrived(name: String, path: String) {
        if AppState.shared.isMirroringPaused { return }
        let content = UNMutableNotificationContent()
        content.title = "File received from phone"
        content.body = name
        content.sound = .default
        content.userInfo = ["filePath": path]
        let id = "file-arrived-\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("file-arrived notification add error: \(err)") }
        }
    }

    // MARK: - Unified Phone Files transfer tracking

    func beginExternalTransfer(
        direction: TransferProgress.Direction,
        name: String,
        size: Int64,
        deviceId: String? = nil,
        deviceName: String? = nil,
        destinationPath: String? = nil,
        itemCount: Int = 1,
        onCancel: @escaping () -> Void
    ) -> String {
        let id = "fs-\(Self.newXid())"
        externalCancelHandlers[id] = onCancel
        AppState.shared.transfers[id] = TransferProgress(
            id: id,
            direction: direction,
            source: .filesBrowse,
            deviceId: deviceId,
            deviceName: deviceName,
            name: name,
            size: size,
            bytesTransferred: 0,
            status: .active,
            destinationPath: destinationPath,
            itemCount: itemCount,
            startedAt: Date()
        )
        return id
    }

    func updateExternalTransfer(
        id: String,
        bytesTransferred: Int64,
        totalSize: Int64? = nil,
        name: String? = nil,
        destinationPath: String? = nil
    ) {
        guard var item = AppState.shared.transfers[id] else { return }
        item.bytesTransferred = bytesTransferred
        if let totalSize { item.size = totalSize }
        if let name { item.name = name }
        if let destinationPath { item.destinationPath = destinationPath }
        AppState.shared.transfers[id] = item
    }

    func finishExternalTransfer(
        id: String,
        status: TransferProgress.Status,
        destinationPath: String? = nil
    ) {
        externalCancelHandlers.removeValue(forKey: id)
        guard var item = AppState.shared.transfers[id] else { return }
        item.status = status
        if case .done = status, item.size > 0 {
            item.bytesTransferred = item.size
        }
        if let destinationPath { item.destinationPath = destinationPath }
        AppState.shared.transfers[id] = item
    }

    func cancel(xid: String) {
        if let externalCancel = externalCancelHandlers.removeValue(forKey: xid) {
            AppState.shared.transfers[xid]?.status = .cancelled
            externalCancel()
            return
        }
        var targetDeviceId: String? = nil
        if let s = incoming.removeValue(forKey: xid) {
            targetDeviceId = s.deviceId
            if s.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
            Self.legacyWriteQueue.async {
                if let h = Self.legacyIncomingHandles.removeValue(forKey: xid) { try? h.close() }
            }
            try? s.handle?.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        if let o = outgoing.removeValue(forKey: xid) {
            targetDeviceId = o.deviceId
            if o.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
        }
        AppState.shared.transfers[xid]?.status = .cancelled
        WsServer.shared.send(.fileCancel(xid: xid, reason: "user_cancelled"), to: targetDeviceId)
    }

    func retry(xid: String) {
        guard let existing = AppState.shared.transfers[xid],
              existing.direction == .outgoing,
              let url = existing.sourceURL else { return }
        let targetDevice = existing.deviceId
        AppState.shared.transfers.removeValue(forKey: xid)
        sendFile(url: url, to: targetDevice)
    }

    func handleCancel(xid: String, reason: String) {
        if let s = incoming.removeValue(forKey: xid) {
            if s.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
            Self.legacyWriteQueue.async {
                if let h = Self.legacyIncomingHandles.removeValue(forKey: xid) { try? h.close() }
            }
            try? s.handle?.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        if let o = outgoing.removeValue(forKey: xid), o.usesBulkHttp {
            BulkTransferServer.shared.cancel(id: xid)
        }
        AppState.shared.transfers[xid]?.status = .cancelled
    }

    func peerDisconnected(deviceId: String? = nil) {
        let matchingIn = incoming.filter { deviceId == nil || $0.value.deviceId == deviceId }
        for (xid, s) in matchingIn {
            incoming.removeValue(forKey: xid)
            if s.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
            Self.legacyWriteQueue.async {
                if let h = Self.legacyIncomingHandles.removeValue(forKey: xid) { try? h.close() }
            }
            try? s.handle?.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        let matchingOut = outgoing.filter { deviceId == nil || $0.value.deviceId == deviceId }
        for (xid, o) in matchingOut {
            outgoing.removeValue(forKey: xid)
            if o.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
        }
        for (k, var v) in AppState.shared.transfers
        where v.source == .direct && (deviceId == nil || v.deviceId == deviceId) {
            if v.isInFlight {
                v.status = .failed("disconnected")
                AppState.shared.transfers[k] = v
            }
        }
    }

    private func failIncoming(xid: String, msg: String) {
        guard let s = incoming.removeValue(forKey: xid) else { return }
        if s.usesBulkHttp { BulkTransferServer.shared.cancel(id: xid) }
        Self.legacyWriteQueue.async {
            if let h = Self.legacyIncomingHandles.removeValue(forKey: xid) { try? h.close() }
        }
        try? s.handle?.close()
        try? FileManager.default.removeItem(at: s.url)
        AppState.shared.transfers[xid]?.status = .failed(msg)
        WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"), to: s.deviceId)
    }

    // MARK: - Helpers

    private static func newXid() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Strips directory components, control characters, path separators, and
    /// leading dots so an untrusted peer filename can never escape the inbox
    /// directory or overwrite hidden config files.
    static func sanitizeFileName(_ raw: String) -> String {
        let lastSegment = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        let strippedScalars = lastSegment.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == ":" || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return scalar
        }
        var cleaned = String(String.UnicodeScalarView(strippedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "file.bin"
        }
        if cleaned.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            if !ext.isEmpty && ext.count <= 20 {
                let maxStem = 200 - ext.count - 1
                let stem = String((cleaned as NSString).deletingPathExtension.prefix(maxStem))
                cleaned = stem.isEmpty ? "file.\(ext)" : "\(stem).\(ext)"
            } else {
                cleaned = String(cleaned.prefix(200))
            }
        }
        return cleaned
    }

    static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let safeName = sanitizeFileName(name)
        let baseDir = dir.standardizedFileURL
        let prefix = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"

        func bounded(_ filename: String) -> URL {
            let candidate = baseDir.appendingPathComponent(filename).standardizedFileURL
            if candidate.path.hasPrefix(prefix) {
                return candidate
            }
            return baseDir.appendingPathComponent("file.bin")
        }

        var url = bounded(safeName)
        if !fm.fileExists(atPath: url.path) { return url }
        let stem = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        for i in 1...999 {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            url = bounded(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        return url
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        default: return nil
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
