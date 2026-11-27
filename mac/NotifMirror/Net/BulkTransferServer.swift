import Foundation
import Network

/// High-throughput TLS HTTP/1.1 streaming data plane for bulk file transfers.
///
/// Bypasses WebSocket framing, RFC 6455 client-side XOR masking, per-chunk
/// headers, and MainActor hops by streaming raw file bytes over direct TLS TCP
/// using the exact same SPKI-pinned self-signed RSA-2048 certificate as
/// `WsServer`. Announced to Android via `hello_ack.dataPort` + `"httpbulk"`.
///
/// Endpoints (authenticated with `Authorization: Bearer <pairingSecret>`):
/// - `POST /upload/<id>`: Phone → Mac streaming upload directly to `FileHandle`.
/// - `GET /download/<id>`: Mac → Phone streaming download with `.contentProcessed`
///   kernel backpressure (constant 256 KiB RAM footprint).
final class BulkTransferServer: @unchecked Sendable {
    static let shared = BulkTransferServer()

    private let ioQueue = DispatchQueue(
        label: "com.notifmirror.app.bulktransfer",
        qos: .userInitiated
    )
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private static let chunkSize = 256 * 1024
    private static let maxHeaderBytes = 16 * 1024
    private static let maxUploadChunkBytes = 4 * 1024 * 1024
    private static let maxRangeChunkBytes = 4 * 1024 * 1024
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    enum BulkError: LocalizedError {
        case cancelled
        case unexpectedEOF(expected: Int64, got: Int64)
        case io(String)
        case http(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Transfer cancelled"
            case let .unexpectedEOF(exp, got): return "Incomplete transfer (\(got)/\(exp) bytes)"
            case let .io(msg): return msg
            case let .http(msg): return msg
            }
        }
    }

    private final class UploadSlot {
        let destination: URL
        var expectedSize: Int64
        let onProgress: @Sendable (Int64, Int64) -> Void
        let onComplete: @Sendable (Result<Int64, Error>) -> Void
        var connection: NWConnection?
        var chunkConnections: [ObjectIdentifier: NWConnection] = [:]
        var chunkHandle: FileHandle?
        var writtenRanges: [(Int64, Int64)] = []
        var lastProgressAt: CFAbsoluteTime = 0
        var finished = false

        init(
            destination: URL,
            expectedSize: Int64,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void,
            onComplete: @escaping @Sendable (Result<Int64, Error>) -> Void
        ) {
            self.destination = destination
            self.expectedSize = expectedSize
            self.onProgress = onProgress
            self.onComplete = onComplete
        }
    }

    private final class DownloadSlot {
        let source: URL
        let onProgress: @Sendable (Int64, Int64) -> Void
        let onComplete: @Sendable (Result<Int64, Error>) -> Void
        var connection: NWConnection?
        var chunkConnections: [ObjectIdentifier: NWConnection] = [:]
        var rangeHandle: FileHandle?
        var fileSize: Int64?
        var servedRanges: [(Int64, Int64)] = []
        var lastProgressAt: CFAbsoluteTime = 0
        var finished = false

        init(
            source: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void,
            onComplete: @escaping @Sendable (Result<Int64, Error>) -> Void
        ) {
            self.source = source
            self.onProgress = onProgress
            self.onComplete = onComplete
        }
    }

    private var uploads: [String: UploadSlot] = [:]
    private var downloads: [String: DownloadSlot] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() throws {
        let identity = try SelfSignedCert.shared.identity()
        guard let secId = sec_identity_create(identity) else {
            throw CertError.parse("sec_identity_create returned nil")
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions, secId
        )

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }

        let l = try NWListener(using: parameters)
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                NSLog("BulkTransferServer listening on port \(self.port)")
            case .failed(let err):
                self.port = 0
                NSLog("BulkTransferServer failed: \(err)")
            case .cancelled:
                self.port = 0
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: ioQueue)
        listener = l
    }

    func restart() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            self.cancelAllLocked()
            do {
                try self.start()
            } catch {
                NSLog("BulkTransferServer restart failed: \(error)")
            }
        }
    }

    // MARK: - Slot registration

    func registerUpload(
        id: String,
        destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (Result<Int64, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            self?.uploads[id] = UploadSlot(
                destination: destination,
                expectedSize: expectedSize,
                onProgress: onProgress,
                onComplete: onComplete
            )
        }
    }

    func registerDownload(
        id: String,
        source: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (Result<Int64, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            self?.downloads[id] = DownloadSlot(
                source: source,
                onProgress: onProgress,
                onComplete: onComplete
            )
        }
    }

    func cancel(id: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let slot = self.uploads.removeValue(forKey: id) {
                self.teardownUploadSlot(slot, deleteFile: true)
                if !slot.finished {
                    slot.finished = true
                    slot.onComplete(.failure(CancellationError()))
                }
            }
            if let slot = self.downloads.removeValue(forKey: id) {
                self.teardownDownloadSlot(slot)
                if !slot.finished {
                    slot.finished = true
                    slot.onComplete(.failure(CancellationError()))
                }
            }
        }
    }

    private func cancelAllLocked() {
        for (_, slot) in uploads {
            teardownUploadSlot(slot, deleteFile: true)
            if !slot.finished {
                slot.finished = true
                slot.onComplete(.failure(BulkError.cancelled))
            }
        }
        uploads.removeAll()
        for (_, slot) in downloads {
            teardownDownloadSlot(slot)
            if !slot.finished {
                slot.finished = true
                slot.onComplete(.failure(BulkError.cancelled))
            }
        }
        downloads.removeAll()
    }

    private func teardownUploadSlot(_ slot: UploadSlot, deleteFile: Bool) {
        slot.connection?.cancel()
        slot.connection = nil
        for conn in slot.chunkConnections.values {
            conn.cancel()
        }
        slot.chunkConnections.removeAll()
        try? slot.chunkHandle?.close()
        slot.chunkHandle = nil
        if deleteFile {
            try? FileManager.default.removeItem(at: slot.destination)
        }
    }

    private func teardownDownloadSlot(_ slot: DownloadSlot) {
        slot.connection?.cancel()
        slot.connection = nil
        for conn in slot.chunkConnections.values {
            conn.cancel()
        }
        slot.chunkConnections.removeAll()
        try? slot.rangeHandle?.close()
        slot.rangeHandle = nil
    }

    // MARK: - Connection & HTTP/1.1 handling

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: ioQueue)
        readHeaders(on: conn, buffer: Data())
    }

    private func readHeaders(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if error != nil {
                conn.cancel()
                return
            }
            var acc = buffer
            if let data, !data.isEmpty {
                acc.append(data)
            }
            if let range = acc.range(of: Self.headerDelimiter) {
                let headerData = acc[..<range.lowerBound]
                let leftover = acc[range.upperBound...]
                self.dispatchRequest(
                    headerData: Data(headerData),
                    initialBody: Data(leftover),
                    on: conn
                )
                return
            }
            if acc.count > Self.maxHeaderBytes || isComplete {
                self.sendSimpleResponse(on: conn, status: "400 Bad Request", body: "bad header")
                return
            }
            self.readHeaders(on: conn, buffer: acc)
        }
    }

    private func dispatchRequest(headerData: Data, initialBody: Data, on conn: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendSimpleResponse(on: conn, status: "400 Bad Request", body: "invalid utf8")
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(on: conn, status: "400 Bad Request", body: "empty request")
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            sendSimpleResponse(on: conn, status: "400 Bad Request", body: "malformed line")
            return
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        guard let auth = headers["authorization"],
              auth.lowercased().hasPrefix("bearer ") else {
            sendSimpleResponse(on: conn, status: "401 Unauthorized", body: "missing auth")
            return
        }
        let token = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard Pairing.shared.verify(token) else {
            sendSimpleResponse(on: conn, status: "401 Unauthorized", body: "invalid auth")
            return
        }

        if method == "POST", path.hasPrefix("/upload/"), path.hasSuffix("/finish") {
            let trimmed = String(path.dropFirst("/upload/".count).dropLast("/finish".count))
            let totalBytes = headers["x-total-bytes"].flatMap { Int64($0) }
            handleUploadFinish(id: trimmed, totalBytes: totalBytes, on: conn)
        } else if method == "PUT", path.hasPrefix("/upload/") {
            let id = String(path.dropFirst("/upload/".count))
            guard let offset = headers["x-chunk-offset"].flatMap({ Int64($0) }), offset >= 0,
                  let contentLength = headers["content-length"].flatMap({ Int64($0) }),
                  contentLength >= 0, contentLength <= Int64(Self.maxUploadChunkBytes) else {
                sendSimpleResponse(on: conn, status: "400 Bad Request", body: "invalid chunk headers")
                return
            }
            handleChunkedUpload(
                ChunkUploadRequest(
                    id: id,
                    offset: offset,
                    contentLength: Int(contentLength),
                    initialBody: initialBody,
                    conn: conn
                )
            )
        } else if method == "POST", path.hasPrefix("/upload/") {
            let id = String(path.dropFirst("/upload/".count))
            let contentLength = headers["content-length"].flatMap { Int64($0) }
            handleUpload(id: id, contentLength: contentLength, initialBody: initialBody, on: conn)
        } else if method == "POST", path.hasPrefix("/download/"), path.hasSuffix("/finish") {
            let trimmed = String(path.dropFirst("/download/".count).dropLast("/finish".count))
            handleDownloadFinish(id: trimmed, on: conn)
        } else if method == "GET", path.hasPrefix("/download/") {
            let id = String(path.dropFirst("/download/".count))
            if let rangeHeader = headers["range"] {
                handleRangeDownload(id: id, rangeHeader: rangeHeader, on: conn)
            } else {
                handleDownload(id: id, on: conn)
            }
        } else {
            sendSimpleResponse(on: conn, status: "404 Not Found", body: "unknown route")
        }
    }

    // MARK: - Streaming Upload (Phone → Mac)

    private func handleUpload(
        id: String,
        contentLength: Int64?,
        initialBody: Data,
        on conn: NWConnection
    ) {
        guard let slot = uploads[id] else {
            sendSimpleResponse(on: conn, status: "404 Not Found", body: "unknown upload")
            return
        }
        slot.connection = conn
        let expected = contentLength ?? slot.expectedSize
        if expected > 0 { slot.expectedSize = expected }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: slot.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: slot.destination)
        fm.createFile(atPath: slot.destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: slot.destination) else {
            finishUpload(id: id, slot: slot, handle: nil, result: .failure(BulkError.io("cannot open destination")))
            sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "io")
            return
        }

        var received: Int64 = 0
        if !initialBody.isEmpty {
            do {
                try handle.write(contentsOf: initialBody)
                received += Int64(initialBody.count)
            } catch {
                finishUpload(id: id, slot: slot, handle: handle, result: .failure(error))
                sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "write failed")
                return
            }
        }

        if expected >= 0 && received >= expected {
            slot.onProgress(received, max(expected, received))
            finishUpload(id: id, slot: slot, handle: handle, result: .success(received))
            sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
            return
        }

        pumpUpload(
            UploadPump(
                id: id,
                slot: slot,
                handle: handle,
                expected: expected,
                received: received,
                lastProgressAt: CFAbsoluteTimeGetCurrent(),
                conn: conn
            )
        )
    }

    private struct UploadPump {
        let id: String
        let slot: UploadSlot
        let handle: FileHandle
        let expected: Int64
        var received: Int64
        var lastProgressAt: CFAbsoluteTime
        let conn: NWConnection
    }

    private func pumpUpload(_ pump: UploadPump) {
        let conn = pump.conn
        let slot = pump.slot
        let handle = pump.handle
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self else {
                try? handle.close()
                conn.cancel()
                return
            }
            if slot.finished {
                try? handle.close()
                conn.cancel()
                return
            }
            var next = pump
            if let data, !data.isEmpty {
                do {
                    try handle.write(contentsOf: data)
                    next.received += Int64(data.count)
                } catch {
                    self.finishUpload(id: next.id, slot: slot, handle: handle, result: .failure(error))
                    self.sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "write failed")
                    return
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - next.lastProgressAt >= 0.1 || (next.expected > 0 && next.received >= next.expected) {
                    next.lastProgressAt = now
                    slot.onProgress(next.received, max(next.expected, next.received))
                }
            }

            if next.expected >= 0 && next.received >= next.expected {
                slot.onProgress(next.received, max(next.expected, next.received))
                self.finishUpload(id: next.id, slot: slot, handle: handle, result: .success(next.received))
                self.sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
                return
            }

            if let error {
                self.finishUpload(id: next.id, slot: slot, handle: handle, result: .failure(error))
                conn.cancel()
                return
            }

            if isComplete {
                if next.expected > 0 && next.received < next.expected {
                    self.finishUpload(
                        id: next.id, slot: slot, handle: handle,
                        result: .failure(BulkError.unexpectedEOF(expected: next.expected, got: next.received))
                    )
                    conn.cancel()
                } else {
                    slot.onProgress(next.received, next.received)
                    self.finishUpload(id: next.id, slot: slot, handle: handle, result: .success(next.received))
                    self.sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
                }
                return
            }

            self.pumpUpload(next)
        }
    }

    private func finishUpload(
        id: String,
        slot: UploadSlot,
        handle: FileHandle?,
        result: Result<Int64, Error>
    ) {
        try? handle?.close()
        if slot.chunkHandle !== handle {
            try? slot.chunkHandle?.close()
        }
        slot.chunkHandle = nil
        for conn in slot.chunkConnections.values {
            conn.cancel()
        }
        slot.chunkConnections.removeAll()
        uploads.removeValue(forKey: id)
        guard !slot.finished else { return }
        slot.finished = true
        if case .failure = result {
            try? FileManager.default.removeItem(at: slot.destination)
        }
        slot.onComplete(result)
    }

    // MARK: - Parallel / Resumable Chunked Upload (Phone → Mac)

    private struct ChunkUploadRequest {
        let id: String
        let offset: Int64
        let contentLength: Int
        let initialBody: Data
        let conn: NWConnection
    }

    private func handleChunkedUpload(_ req: ChunkUploadRequest) {
        guard let slot = uploads[req.id], !slot.finished else {
            sendSimpleResponse(on: req.conn, status: "404 Not Found", body: "unknown upload")
            return
        }
        let connKey = ObjectIdentifier(req.conn)
        slot.chunkConnections[connKey] = req.conn

        if req.initialBody.count >= req.contentLength {
            let chunk = req.initialBody.prefix(req.contentLength)
            commitUploadedChunk(
                id: req.id,
                slot: slot,
                offset: req.offset,
                data: Data(chunk),
                conn: req.conn
            )
            return
        }

        readUploadChunk(req: req, slot: slot, buffer: req.initialBody)
    }

    private func readUploadChunk(req: ChunkUploadRequest, slot: UploadSlot, buffer: Data) {
        let remaining = req.contentLength - buffer.count
        req.conn.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, Self.chunkSize)) { [weak self] data, _, isComplete, error in
            guard let self else { req.conn.cancel(); return }
            let connKey = ObjectIdentifier(req.conn)
            if slot.finished || self.uploads[req.id] !== slot {
                slot.chunkConnections.removeValue(forKey: connKey)
                req.conn.cancel()
                return
            }
            var acc = buffer
            if let data, !data.isEmpty {
                acc.append(data)
            }
            if acc.count >= req.contentLength {
                let exact = acc.count == req.contentLength ? acc : Data(acc.prefix(req.contentLength))
                self.commitUploadedChunk(id: req.id, slot: slot, offset: req.offset, data: exact, conn: req.conn)
                return
            }
            if error != nil || isComplete {
                // Transient per-chunk failure: drop only this connection so the client can retry the chunk.
                slot.chunkConnections.removeValue(forKey: connKey)
                req.conn.cancel()
                return
            }
            self.readUploadChunk(req: req, slot: slot, buffer: acc)
        }
    }

    private func ensureUploadHandle(for slot: UploadSlot) throws -> FileHandle {
        if let existing = slot.chunkHandle {
            return existing
        }
        let fm = FileManager.default
        try fm.createDirectory(
            at: slot.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: slot.destination)
        fm.createFile(atPath: slot.destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: slot.destination)
        if slot.expectedSize > 0 {
            try handle.truncate(atOffset: UInt64(slot.expectedSize))
        }
        slot.chunkHandle = handle
        return handle
    }

    private func commitUploadedChunk(
        id: String,
        slot: UploadSlot,
        offset: Int64,
        data: Data,
        conn: NWConnection
    ) {
        let connKey = ObjectIdentifier(conn)
        defer { slot.chunkConnections.removeValue(forKey: connKey) }
        guard !slot.finished, uploads[id] === slot else {
            conn.cancel()
            return
        }
        do {
            let handle = try ensureUploadHandle(for: slot)
            try handle.seek(toOffset: UInt64(offset))
            if !data.isEmpty {
                try handle.write(contentsOf: data)
                Self.insertRange(&slot.writtenRanges, start: offset, end: offset + Int64(data.count))
            }
        } catch {
            finishUpload(id: id, slot: slot, handle: slot.chunkHandle, result: .failure(error))
            sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "write failed")
            return
        }

        let covered = Self.coveredBytes(slot.writtenRanges)
        let now = CFAbsoluteTimeGetCurrent()
        if now - slot.lastProgressAt >= 0.08 || (slot.expectedSize > 0 && covered >= slot.expectedSize) {
            slot.lastProgressAt = now
            slot.onProgress(covered, max(slot.expectedSize, covered))
        }
        sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
    }

    private func handleUploadFinish(id: String, totalBytes: Int64?, on conn: NWConnection) {
        guard let slot = uploads[id], !slot.finished else {
            sendSimpleResponse(on: conn, status: "404 Not Found", body: "unknown upload")
            return
        }
        let expected = totalBytes ?? slot.expectedSize
        let covered = Self.coveredBytes(slot.writtenRanges)
        let contiguous = expected == 0
            || (slot.writtenRanges.count == 1
                && slot.writtenRanges[0].0 == 0
                && slot.writtenRanges[0].1 == expected)

        if expected > 0 && (!contiguous || covered != expected) {
            sendSimpleResponse(on: conn, status: "409 Conflict", body: "incomplete \(covered)/\(expected)")
            return
        }
        do {
            if expected == 0 && slot.chunkHandle == nil {
                _ = try ensureUploadHandle(for: slot)
            }
            if expected >= 0 {
                try slot.chunkHandle?.truncate(atOffset: UInt64(expected))
            }
        } catch {
            finishUpload(id: id, slot: slot, handle: slot.chunkHandle, result: .failure(error))
            sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "finalize failed")
            return
        }
        slot.onProgress(covered, max(expected, covered))
        finishUpload(id: id, slot: slot, handle: slot.chunkHandle, result: .success(covered))
        sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
    }

    // MARK: - Streaming Download (Mac → Phone)

    private func handleDownload(id: String, on conn: NWConnection) {
        guard let slot = downloads[id] else {
            sendSimpleResponse(on: conn, status: "404 Not Found", body: "unknown download")
            return
        }
        slot.connection = conn

        let attrs = (try? FileManager.default.attributesOfItem(atPath: slot.source.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard let handle = try? FileHandle(forReadingFrom: slot.source) else {
            finishDownload(id: id, slot: slot, handle: nil, result: .failure(BulkError.io("cannot open source")))
            sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "io")
            return
        }

        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(fileSize)\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] err in
            guard let self else {
                try? handle.close()
                conn.cancel()
                return
            }
            if let err {
                self.finishDownload(id: id, slot: slot, handle: handle, result: .failure(err))
                conn.cancel()
                return
            }
            if fileSize == 0 {
                slot.onProgress(0, 0)
                self.finishDownload(id: id, slot: slot, handle: handle, result: .success(0))
                conn.cancel()
                return
            }
            self.pumpDownload(
                DownloadPump(
                    id: id,
                    slot: slot,
                    handle: handle,
                    totalSize: fileSize,
                    sent: 0,
                    lastProgressAt: CFAbsoluteTimeGetCurrent(),
                    conn: conn
                )
            )
        })
    }

    private struct DownloadPump {
        let id: String
        let slot: DownloadSlot
        let handle: FileHandle
        let totalSize: Int64
        var sent: Int64
        var lastProgressAt: CFAbsoluteTime
        let conn: NWConnection
    }

    private func pumpDownload(_ pump: DownloadPump) {
        let slot = pump.slot
        let handle = pump.handle
        let conn = pump.conn
        if slot.finished {
            try? handle.close()
            conn.cancel()
            return
        }
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
        } catch {
            finishDownload(id: pump.id, slot: slot, handle: handle, result: .failure(error))
            conn.cancel()
            return
        }
        if chunk.isEmpty {
            slot.onProgress(pump.sent, pump.totalSize)
            finishDownload(id: pump.id, slot: slot, handle: handle, result: .success(pump.sent))
            conn.cancel()
            return
        }
        var next = pump
        next.sent += Int64(chunk.count)
        let isLast = next.sent >= next.totalSize

        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard let self else {
                try? handle.close()
                conn.cancel()
                return
            }
            if let err {
                self.finishDownload(id: next.id, slot: slot, handle: handle, result: .failure(err))
                conn.cancel()
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if isLast || now - next.lastProgressAt >= 0.1 {
                next.lastProgressAt = now
                slot.onProgress(next.sent, next.totalSize)
            }
            if isLast {
                self.finishDownload(id: next.id, slot: slot, handle: handle, result: .success(next.sent))
                conn.cancel()
                return
            }
            self.pumpDownload(next)
        })
    }

    private func finishDownload(
        id: String,
        slot: DownloadSlot,
        handle: FileHandle?,
        result: Result<Int64, Error>
    ) {
        try? handle?.close()
        if slot.rangeHandle !== handle {
            try? slot.rangeHandle?.close()
        }
        slot.rangeHandle = nil
        for conn in slot.chunkConnections.values {
            conn.cancel()
        }
        slot.chunkConnections.removeAll()
        downloads.removeValue(forKey: id)
        guard !slot.finished else { return }
        slot.finished = true
        slot.onComplete(result)
    }

    // MARK: - Parallel / Resumable Range Download (Mac → Phone)

    private func handleRangeDownload(id: String, rangeHeader: String, on conn: NWConnection) {
        guard let slot = downloads[id], !slot.finished else {
            sendSimpleResponse(on: conn, status: "404 Not Found", body: "unknown download")
            return
        }

        let fileSize: Int64
        if let cached = slot.fileSize {
            fileSize = cached
        } else {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: slot.source.path)) ?? [:]
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            slot.fileSize = fileSize
        }

        if fileSize == 0 {
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n\r\n"
            slot.onProgress(0, 0)
            finishDownload(id: id, slot: slot, handle: slot.rangeHandle, result: .success(0))
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        guard let (reqStart, reqEnd) = Self.parseByteRange(rangeHeader, fileSize: fileSize) else {
            sendSimpleResponse(on: conn, status: "416 Range Not Satisfiable", body: "bad range")
            return
        }
        let clampedEnd = min(reqEnd, reqStart + Int64(Self.maxRangeChunkBytes) - 1, fileSize - 1)
        let length = Int(clampedEnd - reqStart + 1)

        let slice: Data
        do {
            let handle: FileHandle
            if let existing = slot.rangeHandle {
                handle = existing
            } else {
                handle = try FileHandle(forReadingFrom: slot.source)
                slot.rangeHandle = handle
            }
            try handle.seek(toOffset: UInt64(reqStart))
            slice = try handle.read(upToCount: length) ?? Data()
        } catch {
            finishDownload(id: id, slot: slot, handle: slot.rangeHandle, result: .failure(error))
            sendSimpleResponse(on: conn, status: "500 Internal Server Error", body: "read failed")
            return
        }

        let actualEnd = reqStart + Int64(slice.count) - 1
        let header = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Range: bytes \(reqStart)-\(actualEnd)/\(fileSize)\r\n"
            + "Content-Length: \(slice.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(slice)

        let connKey = ObjectIdentifier(conn)
        slot.chunkConnections[connKey] = conn
        conn.send(content: payload, completion: .contentProcessed { [weak self] err in
            defer {
                slot.chunkConnections.removeValue(forKey: connKey)
                conn.cancel()
            }
            guard let self, err == nil, !slot.finished, self.downloads[id] === slot else { return }
            Self.insertRange(&slot.servedRanges, start: reqStart, end: reqStart + Int64(slice.count))
            let covered = Self.coveredBytes(slot.servedRanges)
            let now = CFAbsoluteTimeGetCurrent()
            if now - slot.lastProgressAt >= 0.08 || covered >= fileSize {
                slot.lastProgressAt = now
                slot.onProgress(covered, fileSize)
            }
        })
    }

    private func handleDownloadFinish(id: String, on conn: NWConnection) {
        guard let slot = downloads[id], !slot.finished else {
            // Idempotent: 0-byte or already-finished download still returns 200 OK.
            sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
            return
        }
        let total = slot.fileSize ?? Self.coveredBytes(slot.servedRanges)
        slot.onProgress(total, total)
        finishDownload(id: id, slot: slot, handle: slot.rangeHandle, result: .success(total))
        sendSimpleResponse(on: conn, status: "200 OK", body: "OK")
    }

    private static func parseByteRange(_ header: String, fileSize: Int64) -> (Int64, Int64)? {
        let lower = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let spec = lower.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]), start >= 0, start < fileSize else {
            return nil
        }
        let end: Int64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = Int64(parts[1]), parsedEnd >= start {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }
        return (start, end)
    }

    private static func insertRange(_ ranges: inout [(Int64, Int64)], start: Int64, end: Int64) {
        guard end > start else { return }
        ranges.append((start, end))
        ranges.sort { $0.0 < $1.0 }
        var merged: [(Int64, Int64)] = []
        merged.reserveCapacity(ranges.count)
        for interval in ranges {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }
        ranges = merged
    }

    private static func coveredBytes(_ ranges: [(Int64, Int64)]) -> Int64 {
        ranges.reduce(0) { $0 + ($1.1 - $1.0) }
    }

    private func sendSimpleResponse(on conn: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var full = Data(response.utf8)
        full.append(bodyData)
        conn.send(content: full, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
