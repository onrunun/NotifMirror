import Foundation
import Network

/// TLS WebSocket server supporting multiple simultaneous Android phones.
///
/// Any phone that scans the Mac's pairing QR (same 256-bit secret + RSA-2048
/// SPKI fingerprint) can connect concurrently. Each phone is keyed by its
/// persistent `deviceId` (or fallback `deviceName@host` for older peers) so a
/// reconnect cleanly replaces only that phone's previous socket without
/// disturbing other connected phones.
final class WsServer: @unchecked Sendable {
    static let shared = WsServer()

    private final class ClientSession {
        let deviceId: String
        let deviceName: String
        let host: String?
        let conn: NWConnection
        var features: Set<String>

        init(deviceId: String, deviceName: String, host: String?, conn: NWConnection, features: Set<String>) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.host = host
            self.conn = conn
            self.features = features
        }
    }

    private let queue = DispatchQueue(label: "com.notifmirror.app.wsserver")
    private var listener: NWListener?
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    private var sessionsByDeviceId: [String: ClientSession] = [:]
    private var sessionByConn: [ObjectIdentifier: ClientSession] = [:]
    private var defaultTargetDeviceId: String? = nil

    private init() {}

    static let listenPortPrefKey = "serverListenPort"

    func start() throws {
        // Bring up the TLS HTTP/1.1 bulk data plane first so its ephemeral
        // port is ready to advertise in `hello_ack.dataPort`.
        do {
            try BulkTransferServer.shared.start()
        } catch {
            NSLog("BulkTransferServer start failed (falling back to WS): \(error)")
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 8 * 1024 * 1024

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
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let savedPort = UserDefaults.standard.object(forKey: Self.listenPortPrefKey) as? Int
        let l: NWListener
        if let raw = savedPort, raw > 0, raw <= 65535,
           let nwPort = NWEndpoint.Port(rawValue: UInt16(raw)) {
            l = try NWListener(using: parameters, on: nwPort)
        } else {
            l = try NWListener(using: parameters)
        }
        l.service = NWListener.Service(name: "notifmirror", type: "_andnotif._tcp")

        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = l.port?.rawValue ?? 0
                if port > 0 {
                    UserDefaults.standard.set(Int(port), forKey: Self.listenPortPrefKey)
                }
                Task { @MainActor in
                    AppState.shared.listenerPort = port
                    AppState.shared.isServerListening = true
                    AppState.shared.lastError = nil
                }
                NSLog("WsServer listening on port \(port)")
            case .failed(let err):
                Task { @MainActor in
                    AppState.shared.isServerListening = false
                    AppState.shared.lastError = "Listener failed: \(err.localizedDescription)"
                }
                NSLog("WsServer failed: \(err)")
                UserDefaults.standard.removeObject(forKey: Self.listenPortPrefKey)
                self?.scheduleRestart()
            case .cancelled:
                Task { @MainActor in AppState.shared.isServerListening = false }
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }

        l.start(queue: queue)
        listener = l
    }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            try? self?.start()
        }
    }

    // MARK: - Connection lifecycle

    private func accept(_ conn: NWConnection) {
        pendingConnections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                NSLog("client connection ready")
            case .failed(let err):
                NSLog("client failed: \(err)")
                self.queue.async { self.dropConnection(conn) }
            case .cancelled:
                self.queue.async { self.dropConnection(conn) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func dropConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        pendingConnections.removeValue(forKey: key)
        guard let session = sessionByConn.removeValue(forKey: key) else {
            return
        }
        // Only tear down device state if this socket is still the live session
        // for `session.deviceId` (not an older socket replaced on reconnect).
        guard sessionsByDeviceId[session.deviceId]?.conn === conn else {
            return
        }
        sessionsByDeviceId.removeValue(forKey: session.deviceId)
        if defaultTargetDeviceId == session.deviceId {
            defaultTargetDeviceId = sessionsByDeviceId.keys.sorted().first
        }

        let droppedId = session.deviceId
        Task { @MainActor in
            AppState.shared.removeDevice(id: droppedId)
            FileTransferCenter.shared.peerDisconnected(deviceId: droppedId)
            MediaController.shared.peerDisconnected(deviceId: droppedId)
            ProtocolFileClient.shared.peerDisconnected(deviceId: droppedId)
            BatteryStore.shared.peerDisconnected(deviceId: droppedId)
        }
    }

    private static func extractHost(from conn: NWConnection) -> String? {
        func hostString(_ endpoint: NWEndpoint?) -> String? {
            guard case let .hostPort(host, _) = endpoint else { return nil }
            switch host {
            case .ipv4(let a):
                return a.debugDescription
            case .ipv6(let a):
                let s = a.debugDescription
                return s.split(separator: "%").first.map(String.init) ?? s
            case .name(let n, _):
                return n
            @unknown default:
                return nil
            }
        }
        return hostString(conn.currentPath?.remoteEndpoint) ?? hostString(conn.endpoint)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let self, let conn else { return }
            if let error {
                DebugLog.line("[ws] receive error: \(error)")
                conn.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.handleIncoming(data: data, context: context, on: conn)
            }
            if conn.state != .cancelled {
                self.receive(on: conn)
            }
        }
    }

    private func handleIncoming(data: Data, context: NWConnection.ContentContext?, on conn: NWConnection) {
        let connKey = ObjectIdentifier(conn)
        if let meta = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
            switch meta.opcode {
            case .text:
                break
            case .binary:
                guard let session = sessionByConn[connKey] else { return }
                handleBinaryFrame(data: data, from: session.deviceId)
                return
            case .close:
                conn.cancel()
                return
            default:
                return
            }
        }

        let message: WireMessage
        do {
            message = try WireCodec.decode(data)
        } catch {
            NSLog("decode error: \(error)")
            sendError(on: conn, code: "malformed", msg: "\(error)")
            queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
            return
        }

        guard let session = sessionByConn[connKey] else {
            handleUnauthenticated(message: message, on: conn)
            return
        }
        handleAuthenticated(message: message, session: session)
    }

    private func handleUnauthenticated(message: WireMessage, on conn: NWConnection) {
        switch message {
        case let .hello(secret, deviceName, proto, features, rawDeviceId):
            guard proto >= WireCodec.minAcceptedProtocol,
                  proto <= WireCodec.protocolVersion else {
                sendError(on: conn, code: "bad_proto", msg: "unsupported proto \(proto)")
                queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
                return
            }
            guard Pairing.shared.verify(secret) else {
                sendError(on: conn, code: "bad_secret", msg: "auth failed")
                queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
                return
            }

            let peerHost = Self.extractHost(from: conn)
            let resolvedId: String
            if let rawDeviceId, !rawDeviceId.isEmpty {
                resolvedId = rawDeviceId
            } else {
                resolvedId = "\(deviceName)@\(peerHost ?? "lan")"
            }

            // If this exact phone already had an older socket, replace only it.
            if let previous = sessionsByDeviceId[resolvedId], previous.conn !== conn {
                sessionByConn.removeValue(forKey: ObjectIdentifier(previous.conn))
                previous.conn.cancel()
            }

            let featureSet = Set(features)
            let session = ClientSession(
                deviceId: resolvedId,
                deviceName: deviceName,
                host: peerHost,
                conn: conn,
                features: featureSet
            )
            pendingConnections.removeValue(forKey: ObjectIdentifier(conn))
            sessionsByDeviceId[resolvedId] = session
            sessionByConn[ObjectIdentifier(conn)] = session
            if defaultTargetDeviceId == nil {
                defaultTargetDeviceId = resolvedId
            }

            Task { @MainActor in
                AppState.shared.upsertDevice(
                    id: resolvedId,
                    name: deviceName,
                    host: peerHost,
                    features: featureSet
                )
            }

            let ack = WireMessage.helloAck(
                accepted: true,
                serverName: Host.current().localizedName ?? "Mac",
                features: FeatureRegistry.supported,
                dataPort: Int(BulkTransferServer.shared.port)
            )
            send(ack, on: conn)

            if featureSet.contains("media") {
                send(.mediaCmd(cmd: "refresh", value: nil), on: conn)
            }
            Task { @MainActor in
                WsServer.shared.send(.blocklist(packages: BlockedApps.shared.snapshot()), to: resolvedId)
            }
        default:
            sendError(on: conn, code: "not_authed", msg: "send hello first")
            queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
        }
    }

    private func handleAuthenticated(message: WireMessage, session: ClientSession) {
        let deviceId = session.deviceId
        let deviceName = session.deviceName
        switch message {
        case let .posted(p):
            Task { @MainActor in
                AppState.shared.incrementMirrored()
                if let reqId = AppState.shared.pendingE2ETestReqId,
                   (p.text?.contains(reqId) == true) || (p.title?.contains(reqId) == true) {
                    AppState.shared.pendingE2ETestReqId = nil
                }
                NotificationPresenter.shared.handlePosted(p, from: deviceId, deviceName: deviceName)
            }
        case let .removed(key):
            Task { @MainActor in
                NotificationPresenter.shared.handleRemoved(key: key)
            }
        case let .blocklist(packages):
            Task { @MainActor in
                BlockedApps.shared.applyRemote(packages)
            }
        case let .clip(text, origin, seq):
            if origin != "mac" {
                Task { @MainActor in
                    ClipboardSync.shared.handleRemoteClip(
                        text: text, origin: origin, seq: seq, deviceName: deviceName
                    )
                }
            }
        case let .mediaState(m):
            Task { @MainActor in
                MediaController.shared.handleRemoteState(m, from: deviceId)
            }
        case let .batteryState(b):
            Task { @MainActor in
                BatteryStore.shared.handleRemoteState(b, from: deviceId, deviceName: deviceName)
            }
        case let .fileOffer(offer):
            Task { @MainActor in
                FileTransferCenter.shared.handleOffer(offer, from: deviceId, deviceName: deviceName)
            }
        case let .fileAccept(xid):
            Task { @MainActor in FileTransferCenter.shared.handleAccept(xid: xid) }
        case let .fileReject(xid, reason):
            Task { @MainActor in FileTransferCenter.shared.handleReject(xid: xid, reason: reason) }
        case let .fileChunk(xid, offset, data, last):
            let bytes = Data(base64Encoded: data) ?? Data()
            FileTransferCenter.shared.handleBinaryChunk(
                xid: xid, offset: offset, bytes: bytes, last: last
            )
        case let .fileDone(xid):
            Task { @MainActor in FileTransferCenter.shared.handleDone(xid: xid) }
        case let .fileAck(xid, ok, err):
            Task { @MainActor in FileTransferCenter.shared.handleAck(xid: xid, ok: ok, error: err) }
        case let .fileCancel(xid, reason):
            Task { @MainActor in FileTransferCenter.shared.handleCancel(xid: xid, reason: reason) }
        case .fsListResult, .fsOpResult, .fsDiskResult, .fsDuResult,
             .fsReadResult, .fsWriteReady, .fsChunk, .fsThumbResult:
            Task { @MainActor in ProtocolFileClient.shared.deliver(message) }
        case .fsList, .fsDelete, .fsMkdir, .fsRename, .fsDisk, .fsDu, .fsRead, .fsWrite, .fsCancel, .fsThumb:
            NSLog("unexpected inbound browse request")
        case .ping:
            send(.pong, on: session.conn)
        case .pong:
            break
        case let .error(code, msg):
            NSLog("client error (\(deviceName)): \(code) \(msg)")
        case let .unknown(t):
            NSLog("ignoring unknown message type: \(t)")
        default:
            break
        }
    }

    // MARK: - Outbound Routing

    func setDefaultTargetDevice(_ deviceId: String?) {
        queue.async { [weak self] in
            self?.defaultTargetDeviceId = deviceId
        }
    }

    func sendDismiss(key: String, to deviceId: String? = nil) {
        if let deviceId {
            send(.dismiss(key: key), to: deviceId)
        } else {
            broadcast(.dismiss(key: key))
        }
    }

    @discardableResult
    func sendAction(key: String, actionId: String, text: String?, to deviceId: String? = nil) -> Bool {
        guard isClientAuthed else { return false }
        send(.action(key: key, actionId: actionId, text: text), to: deviceId)
        return true
    }

    func sendTestRequest(reqId: String, to deviceId: String? = nil) {
        send(.testRequest(reqId: reqId), to: deviceId)
    }

    /// Send to a specific device (or the currently active default phone when `deviceId == nil`).
    func send(_ message: WireMessage, to deviceId: String? = nil) {
        queue.async { [weak self] in
            guard let self, let session = self.resolveSession(deviceId) else { return }
            self.send(message, on: session.conn)
        }
    }

    /// Broadcast to all connected phones (optionally filtered by an advertised feature).
    func broadcast(_ message: WireMessage, requiringFeature feature: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.sessionsByDeviceId.values {
                if let feature, !session.features.contains(feature) { continue }
                self.send(message, on: session.conn)
            }
        }
    }

    var isClientAuthed: Bool {
        !sessionsByDeviceId.isEmpty
    }

    func disconnectDevice(_ deviceId: String) {
        queue.async { [weak self] in
            guard let self, let session = self.sessionsByDeviceId[deviceId] else { return }
            session.conn.cancel()
        }
    }

    func restartListener() {
        BulkTransferServer.shared.restart()
        queue.async { [weak self] in
            guard let self else { return }
            let allConns = Array(self.pendingConnections.values)
                + self.sessionsByDeviceId.values.map(\.conn)
            self.pendingConnections.removeAll()
            self.sessionsByDeviceId.removeAll()
            self.sessionByConn.removeAll()
            self.defaultTargetDeviceId = nil
            allConns.forEach { $0.cancel() }
            self.listener?.cancel()
            self.listener = nil
            Task { @MainActor in
                AppState.shared.removeAllDevices()
                AppState.shared.isServerListening = false
                FileTransferCenter.shared.peerDisconnected(deviceId: nil)
                MediaController.shared.peerDisconnected(deviceId: nil)
                ProtocolFileClient.shared.peerDisconnected(deviceId: nil)
                BatteryStore.shared.peerDisconnected(deviceId: nil)
            }
            do {
                try self.start()
            } catch {
                NSLog("WsServer restart failed: \(error)")
                Task { @MainActor in
                    AppState.shared.lastError = "TLS restart failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnectActiveClient() {
        queue.async { [weak self] in
            guard let self else { return }
            let allConns = Array(self.pendingConnections.values)
                + self.sessionsByDeviceId.values.map(\.conn)
            self.pendingConnections.removeAll()
            self.sessionsByDeviceId.removeAll()
            self.sessionByConn.removeAll()
            self.defaultTargetDeviceId = nil
            allConns.forEach { $0.cancel() }
            Task { @MainActor in
                AppState.shared.removeAllDevices()
                FileTransferCenter.shared.peerDisconnected(deviceId: nil)
                MediaController.shared.peerDisconnected(deviceId: nil)
                ProtocolFileClient.shared.peerDisconnected(deviceId: nil)
                BatteryStore.shared.peerDisconnected(deviceId: nil)
            }
        }
    }

    private func resolveSession(_ deviceId: String?) -> ClientSession? {
        if let deviceId, let match = sessionsByDeviceId[deviceId] {
            return match
        }
        if let def = defaultTargetDeviceId, let match = sessionsByDeviceId[def] {
            return match
        }
        return sessionsByDeviceId.values.first
    }

    // MARK: - Legacy Binary Chunk Framing (fallback for non-httpbulk peers)

    static let chunkKindFile:      UInt8 = 0x01
    static let chunkKindFs:        UInt8 = 0x02
    static let chunkKindHeartbeat: UInt8 = 0xFE

    func sendBinaryChunk(
        kind: UInt8,
        id: String,
        offset: Int64,
        payload: Data,
        last: Bool,
        to deviceId: String? = nil,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        guard let idBytes = id.data(using: .ascii), idBytes.count == 8 else {
            NSLog("sendBinaryChunk: bad id \(id)")
            completion?(nil)
            return
        }
        var buf = Data(capacity: 18 + payload.count)
        buf.append(kind)
        buf.append(idBytes)
        let uo = UInt64(bitPattern: offset)
        for i in 0..<8 {
            buf.append(UInt8((uo >> ((7 - i) * 8)) & 0xFF))
        }
        buf.append(last ? 0x01 : 0x00)
        buf.append(payload)

        queue.async { [weak self] in
            guard let self, let session = self.resolveSession(deviceId) else {
                completion?(nil)
                return
            }
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "bin", metadata: [meta])
            session.conn.send(content: buf, contentContext: context, isComplete: true,
                              completion: .contentProcessed { err in
                if let err { NSLog("sendBinary err: \(err)") }
                completion?(err)
            })
        }
    }

    private func handleBinaryFrame(data: Data, from deviceId: String) {
        guard let firstByte = data.first else { return }
        if firstByte == Self.chunkKindHeartbeat { return }
        guard data.count >= 18 else { return }
        let base = data.startIndex
        let kind = data[base]
        let flagsByte = data[base + 17]
        guard let id = String(data: data[(base + 1)..<(base + 9)], encoding: .ascii) else {
            return
        }
        var offU: UInt64 = 0
        for i in 0..<8 {
            offU = (offU << 8) | UInt64(data[base + 9 + i])
        }
        let offset = Int64(bitPattern: offU)
        let last = (flagsByte & 0x01) != 0
        let payload: Data = data.count > 18
            ? data.subdata(in: (base + 18)..<data.endIndex)
            : Data()

        switch kind {
        case Self.chunkKindFile:
            FileTransferCenter.shared.handleBinaryChunk(
                xid: id, offset: offset, bytes: payload, last: last
            )
        case Self.chunkKindFs:
            ProtocolFileClient.shared.handleBinaryChunk(
                reqId: id, offset: offset, bytes: payload, last: last, from: deviceId
            )
        default:
            break
        }
    }

    private func send(_ message: WireMessage, on conn: NWConnection) {
        let data: Data
        do { data = try WireCodec.encode(message) } catch {
            NSLog("encode error: \(error)"); return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: context, isComplete: true,
                  completion: .contentProcessed { err in
            if let err { NSLog("send err: \(err)") }
        })
    }

    private func sendError(on conn: NWConnection, code: String, msg: String) {
        send(.error(code: code, msg: msg), on: conn)
    }
}

enum FeatureRegistry {
    static let supported: [String] = ["clip", "media", "file", "fsbrowse", "fsthumb", "httpbulk"]
}
