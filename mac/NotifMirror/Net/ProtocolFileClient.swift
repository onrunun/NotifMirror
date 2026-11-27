import AppKit
import Foundation

/// Opt-in, debug-only diagnostic file logger.
///
/// Strictly compiled out in Release builds so file paths and frame telemetry
/// are never written to disk. In Debug builds, opt in via
/// `defaults write com.notifmirror.app debugFileLogging -bool YES`; logs write
/// into the user-private Caches directory (mode 0600, capped at 2 MiB) rather
/// than world-readable `/tmp`.
enum DebugLog {
    #if DEBUG
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let enabled = UserDefaults.standard.bool(forKey: "debugFileLogging")
    private static let fileURL: URL? = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = caches.appendingPathComponent("NotifMirror", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("debug.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "com.notifmirror.app.debuglog")
    #endif

    static func line(_ message: String) {
        #if DEBUG
        guard enabled, let url = fileURL else { return }
        let stamped = "\(fmt.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64,
               size >= maxBytes {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(
                    atPath: url.path,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                )
            } else if let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        }
        #endif
    }
}

/// Browses / reads / writes a paired phone's filesystem over the WebSocket
/// control channel + `BulkTransferServer` (TLS HTTP/1.1 streaming for fast
/// file reads/writes, with seamless WS binary fallback for older peers).
@MainActor
final class ProtocolFileClient {
    static let shared = ProtocolFileClient()

    private init() {}

    private nonisolated static let chunkSize: Int = 256 * 1024

    private static let chunkWriteQueue = DispatchQueue(
        label: "com.notifmirror.app.fsChunkWrite",
        qos: .userInitiated
    )

    // MARK: - Pending op tracking

    private final class Pending {
        var deviceId: String? = nil
        var usesBulkHttp: Bool = false

        var resumeList: CheckedContinuation<([WireMessage.FsEntry], String?), Error>? = nil
        var resumeOp: CheckedContinuation<Void, Error>? = nil
        var resumeDisk: CheckedContinuation<(Int64, Int64), Error>? = nil
        var resumeDu: CheckedContinuation<DiskUsageReport, Error>? = nil
        var resumeThumb: CheckedContinuation<Data, Error>? = nil

        var resumeRead: CheckedContinuation<Void, Error>? = nil
        var readHandle: FileHandle? = nil
        var readExpectedSize: Int64 = 0
        var readBytesSoFar: Int64 = 0
        var readProgress: ((Double) -> Void)? = nil
        var lastProgressAt: CFAbsoluteTime = 0
        var lastChunkAt: CFAbsoluteTime = 0

        var resumeWriteReady: CheckedContinuation<Void, Error>? = nil
        var resumeWriteDone: CheckedContinuation<Void, Error>? = nil
    }

    private var pending: [String: Pending] = [:]
    private var cancelledReqs: Set<String> = []

    /// Bounded in-memory LRU thumbnail cache keyed by `"<deviceId>:<path>@<mtime>"`.
    private let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    /// Off-main storage for legacy WS binary chunks so incoming bytes write
    /// sequentially on `chunkWriteQueue` without bouncing through `@MainActor`.
    private nonisolated(unsafe) static var legacyHandles: [String: FileHandle] = [:]

    struct FsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func resolveDeviceId(_ explicit: String?) -> String? {
        explicit ?? AppState.shared.activeDeviceId
    }

    private func canUseBulkHttp(for deviceId: String?) -> Bool {
        guard BulkTransferServer.shared.port > 0,
              let dev = AppState.shared.device(id: deviceId) else {
            return false
        }
        return dev.features.contains("httpbulk")
    }

    // MARK: - Thumbnails

    func cachedThumbnail(for key: String) -> NSImage? {
        thumbCache.object(forKey: key as NSString)
    }

    func thumbnailImage(
        path: String,
        cacheKey: String,
        deviceId: String? = nil,
        maxDim: Int = 240
    ) async throws -> NSImage {
        if let hit = thumbCache.object(forKey: cacheKey as NSString) {
            return hit
        }
        let data = try await thumbnail(path: path, deviceId: deviceId, maxDim: maxDim)
        guard let image = NSImage(data: data) else {
            throw FsError(message: "invalid thumbnail image")
        }
        thumbCache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    func thumbnail(path: String, deviceId: String? = nil, maxDim: Int = 240) async throws -> Data {
        let reqId = Self.makeReqId()
        let target = resolveDeviceId(deviceId)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                let slot = Pending()
                slot.deviceId = target
                slot.resumeThumb = cont
                pending[reqId] = slot
                WsServer.shared.send(.fsThumb(reqId: reqId, path: path, maxDim: maxDim), to: target)
            }
        } onCancel: {
            Task { @MainActor in
                if let slot = ProtocolFileClient.shared.pending.removeValue(forKey: reqId) {
                    let cont = slot.resumeThumb
                    slot.resumeThumb = nil
                    cont?.resume(throwing: CancellationError())
                }
            }
        }
    }

    // MARK: - Metadata RPCs

    func list(path: String, deviceId: String? = nil) async throws -> [AdbEntry] {
        let reqId = Self.makeReqId()
        let target = resolveDeviceId(deviceId)
        let result: ([WireMessage.FsEntry], String?) = try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.deviceId = target
            slot.resumeList = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsList(reqId: reqId, path: path), to: target)
        }
        if let err = result.1 { throw FsError(message: err) }
        return result.0.map { Self.toAdbEntry($0) }
    }

    func delete(path: String, deviceId: String? = nil) async throws {
        try await opCall(deviceId: deviceId) { reqId in .fsDelete(reqId: reqId, path: path) }
    }

    func mkdir(path: String, deviceId: String? = nil) async throws {
        try await opCall(deviceId: deviceId) { reqId in .fsMkdir(reqId: reqId, path: path) }
    }

    func rename(from: String, to: String, deviceId: String? = nil) async throws {
        try await opCall(deviceId: deviceId) { reqId in .fsRename(reqId: reqId, from: from, to: to) }
    }

    func diskUsage(path: String, deviceId: String? = nil) async throws -> (free: Int64, total: Int64) {
        let reqId = Self.makeReqId()
        let target = resolveDeviceId(deviceId)
        let pair: (Int64, Int64) = try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.deviceId = target
            slot.resumeDisk = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsDisk(reqId: reqId, path: path), to: target)
        }
        return (free: pair.0, total: pair.1)
    }

    func diskAnalyze(path: String, deviceId: String? = nil) async throws -> DiskUsageReport {
        let reqId = Self.makeReqId()
        let target = resolveDeviceId(deviceId)
        return try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.deviceId = target
            slot.resumeDu = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsDu(reqId: reqId, path: path), to: target)
        }
    }

    // MARK: - Pull (Phone → Mac)

    func pull(
        remote: String,
        to local: URL,
        deviceId: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let target = resolveDeviceId(deviceId)
        if canUseBulkHttp(for: target) {
            try await pullViaBulkHttp(remote: remote, to: local, deviceId: target, onProgress: onProgress)
            return
        }
        try await pullViaLegacyWs(remote: remote, to: local, deviceId: target, onProgress: onProgress)
    }

    private func pullViaBulkHttp(
        remote: String,
        to local: URL,
        deviceId: String?,
        onProgress: ((Double) -> Void)?
    ) async throws {
        let reqId = Self.makeReqId()
        let slot = Pending()
        slot.deviceId = deviceId
        slot.usesBulkHttp = true
        slot.readProgress = onProgress
        pending[reqId] = slot

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    pending.removeValue(forKey: reqId)
                    cont.resume(throwing: CancellationError())
                    return
                }
                slot.resumeRead = cont
                BulkTransferServer.shared.registerUpload(
                    id: reqId,
                    destination: local,
                    expectedSize: 0,
                    onProgress: { bytes, total in
                        guard let onProgress else { return }
                        let pct = total > 0 ? min(1.0, Double(bytes) / Double(total)) : 0
                        Task { @MainActor in onProgress(pct) }
                    },
                    onComplete: { result in
                        Task { @MainActor in
                            guard let active = ProtocolFileClient.shared.pending.removeValue(forKey: reqId) else {
                                return
                            }
                            let c = active.resumeRead
                            active.resumeRead = nil
                            switch result {
                            case .success:
                                c?.resume()
                            case let .failure(err):
                                c?.resume(throwing: err)
                            }
                        }
                    }
                )
                WsServer.shared.send(.fsRead(reqId: reqId, path: remote), to: deviceId)
            }
        } onCancel: {
            Task { @MainActor in
                ProtocolFileClient.shared.cancelPull(reqId: reqId)
            }
        }
    }

    private func pullViaLegacyWs(
        remote: String,
        to local: URL,
        deviceId: String?,
        onProgress: ((Double) -> Void)?
    ) async throws {
        let reqId = Self.makeReqId()
        let fm = FileManager.default
        try? fm.removeItem(at: local)
        fm.createFile(atPath: local.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: local) else {
            throw FsError(message: "cannot open \(local.path) for write")
        }

        let slot = Pending()
        slot.deviceId = deviceId
        slot.readHandle = handle
        slot.readProgress = onProgress
        slot.lastChunkAt = CFAbsoluteTimeGetCurrent()
        pending[reqId] = slot
        Self.chunkWriteQueue.async { Self.legacyHandles[reqId] = handle }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        pending.removeValue(forKey: reqId)
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    slot.resumeRead = cont
                    WsServer.shared.send(.fsRead(reqId: reqId, path: remote), to: deviceId)
                }
            } onCancel: {
                Task { @MainActor in
                    ProtocolFileClient.shared.cancelPull(reqId: reqId)
                }
            }
        } catch {
            Self.chunkWriteQueue.async {
                if let h = Self.legacyHandles.removeValue(forKey: reqId) { try? h.close() }
            }
            try? fm.removeItem(at: local)
            pending.removeValue(forKey: reqId)
            throw error
        }

        Self.chunkWriteQueue.async {
            if let h = Self.legacyHandles.removeValue(forKey: reqId) { try? h.close() }
        }
        pending.removeValue(forKey: reqId)
    }

    private func cancelPull(reqId: String) {
        guard let slot = pending.removeValue(forKey: reqId) else { return }
        if slot.usesBulkHttp {
            BulkTransferServer.shared.cancel(id: reqId)
        }
        if cancelledReqs.insert(reqId).inserted {
            WsServer.shared.send(.fsCancel(reqId: reqId, reason: "user_cancelled"), to: slot.deviceId)
        }
        let cont = slot.resumeRead
        slot.resumeRead = nil
        cont?.resume(throwing: CancellationError())
    }

    // MARK: - Push (Mac → Phone)

    func push(
        local: URL,
        to remotePath: String,
        deviceId: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let target = resolveDeviceId(deviceId)
        if canUseBulkHttp(for: target) {
            try await pushViaBulkHttp(local: local, to: remotePath, deviceId: target, onProgress: onProgress)
            return
        }
        try await pushViaLegacyWs(local: local, to: remotePath, deviceId: target, onProgress: onProgress)
    }

    private func pushViaBulkHttp(
        local: URL,
        to remotePath: String,
        deviceId: String?,
        onProgress: ((Double) -> Void)?
    ) async throws {
        let reqId = Self.makeReqId()
        let attrs = (try? FileManager.default.attributesOfItem(atPath: local.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let slot = Pending()
        slot.deviceId = deviceId
        slot.usesBulkHttp = true
        pending[reqId] = slot

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    pending.removeValue(forKey: reqId)
                    cont.resume(throwing: CancellationError())
                    return
                }
                slot.resumeWriteDone = cont
                BulkTransferServer.shared.registerDownload(
                    id: reqId,
                    source: local,
                    onProgress: { sent, total in
                        guard let onProgress else { return }
                        let pct = total > 0 ? min(1.0, Double(sent) / Double(total)) : 1.0
                        Task { @MainActor in onProgress(pct) }
                    },
                    onComplete: { result in
                        if case let .failure(err) = result {
                            Task { @MainActor in
                                guard let active = ProtocolFileClient.shared.pending.removeValue(forKey: reqId) else {
                                    return
                                }
                                let c = active.resumeWriteDone
                                active.resumeWriteDone = nil
                                c?.resume(throwing: err)
                            }
                        }
                    }
                )
                WsServer.shared.send(.fsWrite(reqId: reqId, path: remotePath, size: size), to: deviceId)
            }
        } onCancel: {
            Task { @MainActor in
                if let active = ProtocolFileClient.shared.pending.removeValue(forKey: reqId) {
                    BulkTransferServer.shared.cancel(id: reqId)
                    WsServer.shared.send(.fsCancel(reqId: reqId, reason: "user_cancelled"), to: active.deviceId)
                    let c = active.resumeWriteDone
                    active.resumeWriteDone = nil
                    c?.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func pushViaLegacyWs(
        local: URL,
        to remotePath: String,
        deviceId: String?,
        onProgress: ((Double) -> Void)?
    ) async throws {
        let reqId = Self.makeReqId()
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: local.path)[.size] as? Int64),
              let handle = try? FileHandle(forReadingFrom: local) else {
            throw FsError(message: "cannot read \(local.path)")
        }

        let slot = Pending()
        slot.deviceId = deviceId
        pending[reqId] = slot

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                slot.resumeWriteReady = cont
                WsServer.shared.send(.fsWrite(reqId: reqId, path: remotePath, size: size), to: deviceId)
            }
        } catch {
            try? handle.close()
            pending.removeValue(forKey: reqId)
            throw error
        }

        let streamResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            defer { try? handle.close() }
            var offset: Int64 = 0
            while true {
                if Task.isCancelled { return .failure(CancellationError()) }
                let data = handle.readData(ofLength: Self.chunkSize)
                if data.isEmpty && offset > 0 { return .success(()) }
                let isLast = (offset + Int64(data.count) >= size)

                await withCheckedContinuation { (sentCont: CheckedContinuation<Void, Never>) in
                    WsServer.shared.sendBinaryChunk(
                        kind: WsServer.chunkKindFs,
                        id: reqId,
                        offset: offset,
                        payload: data,
                        last: isLast,
                        to: deviceId
                    ) { _ in sentCont.resume() }
                }

                offset += Int64(data.count)
                if let cb = onProgress {
                    let pct = size > 0 ? min(1.0, Double(offset) / Double(size)) : 1.0
                    await MainActor.run { cb(pct) }
                }
                if isLast { return .success(()) }
            }
        }.value

        if case let .failure(error) = streamResult {
            WsServer.shared.send(.fsCancel(reqId: reqId, reason: "user_cancelled"), to: deviceId)
            pending.removeValue(forKey: reqId)
            throw error
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                slot.resumeWriteDone = cont
            }
        } catch {
            pending.removeValue(forKey: reqId)
            throw error
        }
        pending.removeValue(forKey: reqId)
    }

    // MARK: - Inbound dispatch

    func deliver(_ message: WireMessage) {
        switch message {
        case let .fsListResult(reqId, _, entries, error):
            if let slot = pending.removeValue(forKey: reqId) {
                slot.resumeList?.resume(returning: (entries, error))
            }
        case let .fsOpResult(reqId, ok, error):
            guard let slot = pending[reqId] else { return }
            if let cont = slot.resumeOp {
                pending.removeValue(forKey: reqId)
                if ok { cont.resume() }
                else { cont.resume(throwing: FsError(message: error ?? "operation failed")) }
                return
            }
            if let cont = slot.resumeWriteDone {
                pending.removeValue(forKey: reqId)
                slot.resumeWriteDone = nil
                if ok { cont.resume() }
                else { cont.resume(throwing: FsError(message: error ?? "write failed")) }
                return
            }
        case let .fsDiskResult(reqId, free, total, error):
            if let slot = pending.removeValue(forKey: reqId) {
                if let err = error { slot.resumeDisk?.resume(throwing: FsError(message: err)) }
                else { slot.resumeDisk?.resume(returning: (free, total)) }
            }
        case let .fsDuResult(reqId, path, totalSize, entries, error):
            if let slot = pending.removeValue(forKey: reqId) {
                if let err = error {
                    slot.resumeDu?.resume(throwing: FsError(message: err))
                } else {
                    slot.resumeDu?.resume(returning: DiskUsageReport(
                        path: path, totalSize: totalSize, entries: entries
                    ))
                }
            }
        case let .fsReadResult(reqId, size, error):
            guard let slot = pending[reqId] else { return }
            if let err = error {
                pending.removeValue(forKey: reqId)
                if slot.usesBulkHttp { BulkTransferServer.shared.cancel(id: reqId) }
                let cont = slot.resumeRead
                slot.resumeRead = nil
                cont?.resume(throwing: FsError(message: err))
                return
            }
            slot.readExpectedSize = size
        case let .fsChunk(reqId, offset, data, last):
            let bytes = Data(base64Encoded: data) ?? Data()
            handleBinaryChunk(reqId: reqId, offset: offset, bytes: bytes, last: last, from: nil)
        case let .fsWriteReady(reqId, error):
            guard let slot = pending[reqId] else { return }
            if let err = error {
                pending.removeValue(forKey: reqId)
                slot.resumeWriteReady?.resume(throwing: FsError(message: err))
                return
            }
            slot.resumeWriteReady?.resume()
            slot.resumeWriteReady = nil
        case let .fsThumbResult(reqId, data, error):
            if let slot = pending.removeValue(forKey: reqId) {
                let cont = slot.resumeThumb
                slot.resumeThumb = nil
                if let err = error {
                    cont?.resume(throwing: FsError(message: err))
                } else if let b64 = data, let raw = Data(base64Encoded: b64) {
                    cont?.resume(returning: raw)
                } else {
                    cont?.resume(throwing: FsError(message: "invalid thumbnail"))
                }
            }
        default:
            break
        }
    }

    /// Legacy WS binary chunk receiver — writes directly on `chunkWriteQueue`
    /// without bouncing through `@MainActor` per chunk.
    nonisolated func handleBinaryChunk(
        reqId: String,
        offset: Int64,
        bytes: Data,
        last: Bool,
        from deviceId: String?
    ) {
        Self.chunkWriteQueue.async {
            guard let handle = Self.legacyHandles[reqId] else {
                Task { @MainActor in
                    if ProtocolFileClient.shared.pending[reqId] == nil,
                       ProtocolFileClient.shared.cancelledReqs.insert(reqId).inserted {
                        WsServer.shared.send(.fsCancel(reqId: reqId, reason: "unknown_reqId"), to: deviceId)
                    }
                }
                return
            }
            if !bytes.isEmpty {
                try? handle.seek(toOffset: UInt64(offset))
                try? handle.write(contentsOf: bytes)
            }
            let soFar = offset + Int64(bytes.count)
            let now = CFAbsoluteTimeGetCurrent()
            if last {
                _ = Self.legacyHandles.removeValue(forKey: reqId)
                try? handle.close()
            }
            Task { @MainActor in
                guard let slot = ProtocolFileClient.shared.pending[reqId] else { return }
                slot.readBytesSoFar = soFar
                slot.lastChunkAt = now
                if let cb = slot.readProgress, slot.readExpectedSize > 0,
                   last || now - slot.lastProgressAt >= 0.1 {
                    slot.lastProgressAt = now
                    cb(min(1.0, Double(soFar) / Double(slot.readExpectedSize)))
                }
                if last {
                    ProtocolFileClient.shared.pending.removeValue(forKey: reqId)
                    let cont = slot.resumeRead
                    slot.resumeRead = nil
                    cont?.resume()
                }
            }
        }
    }

    func peerDisconnected(deviceId: String? = nil) {
        let err = FsError(message: "disconnected")
        let matchingKeys: [String]
        if let deviceId {
            matchingKeys = pending.compactMap { $0.value.deviceId == deviceId ? $0.key : nil }
        } else {
            cancelledReqs.removeAll()
            matchingKeys = Array(pending.keys)
        }
        for key in matchingKeys {
            guard let slot = pending.removeValue(forKey: key) else { continue }
            if slot.usesBulkHttp { BulkTransferServer.shared.cancel(id: key) }
            slot.resumeList?.resume(throwing: err)
            slot.resumeOp?.resume(throwing: err)
            slot.resumeDisk?.resume(throwing: err)
            slot.resumeDu?.resume(throwing: err)
            slot.resumeThumb?.resume(throwing: err)
            slot.resumeThumb = nil
            slot.resumeRead?.resume(throwing: err)
            slot.resumeRead = nil
            slot.resumeWriteReady?.resume(throwing: err)
            slot.resumeWriteDone?.resume(throwing: err)
            slot.resumeWriteDone = nil
            Self.chunkWriteQueue.async {
                if let h = Self.legacyHandles.removeValue(forKey: key) { try? h.close() }
            }
        }
    }

    // MARK: - Helpers

    private func opCall(deviceId: String?, _ makeMsg: (String) -> WireMessage) async throws {
        let reqId = Self.makeReqId()
        let target = resolveDeviceId(deviceId)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let slot = Pending()
            slot.deviceId = target
            slot.resumeOp = cont
            pending[reqId] = slot
            WsServer.shared.send(makeMsg(reqId), to: target)
        }
    }

    private static func makeReqId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func toAdbEntry(_ e: WireMessage.FsEntry) -> AdbEntry {
        let kind: AdbEntry.Kind
        switch e.kind {
        case .dir:   kind = .directory
        case .file:  kind = .file
        case .link:  kind = .symlink
        case .other: kind = .other
        }
        return AdbEntry(
            name: e.name,
            kind: kind,
            size: e.size,
            mtime: Date(timeIntervalSince1970: TimeInterval(e.mtime))
        )
    }
}
