import Foundation
@testable import NotifMirror
import XCTest

/// End-to-end localhost TLS HTTP/1.1 round-trip tests for `BulkTransferServer`
/// verifying upload (`POST /upload/<id>`), download (`GET /download/<id>`),
/// and constant-time Bearer secret rejection (`401`).
final class BulkTransferServerTests: XCTestCase {

    private final class SelfSignedDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private func ensureServerAndSecret() async throws -> (UInt16, String) {
        let secret = Pairing.shared.loadSecret() ?? Pairing.shared.regenerateSecret()
        if BulkTransferServer.shared.port == 0 {
            try BulkTransferServer.shared.start()
        }
        let deadline = Date().addingTimeInterval(5)
        while BulkTransferServer.shared.port == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let port = BulkTransferServer.shared.port
        XCTAssertGreaterThan(port, 0, "BulkTransferServer should bind an ephemeral port")
        return (port, secret)
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg, delegate: SelfSignedDelegate(), delegateQueue: nil)
    }

    func testUploadAndDownloadRoundTripAndAuth() async throws {
        let (port, secret) = try await ensureServerAndSecret()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 2 MiB deterministic payload (exercises multi-chunk 256 KiB streaming).
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 & 0xFF) })

        // 1. Unauthorized upload must return 401.
        var badReq = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/upload/unauth01")!)
        badReq.httpMethod = "POST"
        badReq.setValue("Bearer wrong-secret", forHTTPHeaderField: "Authorization")
        let (_, badResp) = try await session.upload(for: badReq, from: Data("hi".utf8))
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 401)

        // 2. Authorized streaming upload (Phone → Mac).
        let uploadDest = tempDir.appendingPathComponent("uploaded.bin")
        let uploadDone = expectation(description: "upload completes")
        var uploadedBytes: Int64 = 0
        BulkTransferServer.shared.registerUpload(
            id: "up123456",
            destination: uploadDest,
            expectedSize: Int64(payload.count),
            onProgress: { _, _ in },
            onComplete: { result in
                if case let .success(n) = result { uploadedBytes = n }
                uploadDone.fulfill()
            }
        )

        var upReq = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/upload/up123456")!)
        upReq.httpMethod = "POST"
        upReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (_, upResp) = try await session.upload(for: upReq, from: payload)
        XCTAssertEqual((upResp as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [uploadDone], timeout: 5)
        XCTAssertEqual(uploadedBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: uploadDest), payload)

        // 3. Authorized streaming download (Mac → Phone).
        let downloadDone = expectation(description: "download completes")
        var downloadedCount: Int64 = 0
        BulkTransferServer.shared.registerDownload(
            id: "dl123456",
            source: uploadDest,
            onProgress: { _, _ in },
            onComplete: { result in
                if case let .success(n) = result { downloadedCount = n }
                downloadDone.fulfill()
            }
        )

        var dlReq = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/download/dl123456")!)
        dlReq.httpMethod = "GET"
        dlReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (dlData, dlResp) = try await session.data(for: dlReq)
        XCTAssertEqual((dlResp as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [downloadDone], timeout: 5)
        XCTAssertEqual(downloadedCount, Int64(payload.count))
        XCTAssertEqual(dlData, payload)
    }

    func testChunkedUploadAndRangeDownloadRoundTrip() async throws {
        let (port, secret) = try await ensureServerAndSecret()
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-chunk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 512 KiB deterministic payload split into 64 KiB out-of-order chunks + overlapping retry.
        let total = 512 * 1024
        let payload = Data((0..<total).map { UInt8(($0 * 31) & 0xFF) })
        let uploadDest = tempDir.appendingPathComponent("chunked.bin")
        let uploadDone = expectation(description: "chunked upload completes")
        var uploadedBytes: Int64 = 0
        BulkTransferServer.shared.registerUpload(
            id: "chunkup1",
            destination: uploadDest,
            expectedSize: Int64(total),
            onProgress: { _, _ in },
            onComplete: { result in
                if case let .success(n) = result { uploadedBytes = n }
                uploadDone.fulfill()
            }
        )

        let chunkLen = 64 * 1024
        // Send chunks out of order (7, 5, 3, 1, 6, 4, 2, 0) plus a duplicate retry of chunk 3.
        let order = [7, 5, 3, 1, 6, 4, 2, 3, 0]
        for idx in order {
            let start = idx * chunkLen
            let slice = payload.subdata(in: start..<(start + chunkLen))
            var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/upload/chunkup1")!)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            req.setValue("\(start)", forHTTPHeaderField: "X-Chunk-Offset")
            let (_, resp) = try await session.upload(for: req, from: slice)
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        }

        // Finalize upload.
        var finReq = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/upload/chunkup1/finish")!)
        finReq.httpMethod = "POST"
        finReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        finReq.setValue("\(total)", forHTTPHeaderField: "X-Total-Bytes")
        let (_, finResp) = try await session.data(for: finReq)
        XCTAssertEqual((finResp as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [uploadDone], timeout: 5)
        XCTAssertEqual(uploadedBytes, Int64(total))
        XCTAssertEqual(try Data(contentsOf: uploadDest), payload)

        // Range download in 32 KiB slices (206 Partial Content) + finish.
        let dlDone = expectation(description: "range download completes")
        var downloadedCount: Int64 = 0
        BulkTransferServer.shared.registerDownload(
            id: "rangedl1",
            source: uploadDest,
            onProgress: { _, _ in },
            onComplete: { result in
                if case let .success(n) = result { downloadedCount = n }
                dlDone.fulfill()
            }
        )

        var assembled = Data(capacity: total)
        let rangeStep = 32 * 1024
        var offset = 0
        while offset < total {
            let end = min(offset + rangeStep - 1, total - 1)
            var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/download/rangedl1")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (slice, resp) = try await session.data(for: req)
            let http = try XCTUnwrap(resp as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 206)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes \(offset)-\(end)/\(total)")
            assembled.append(slice)
            offset = end + 1
        }

        var dlFin = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/download/rangedl1/finish")!)
        dlFin.httpMethod = "POST"
        dlFin.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (_, dlFinResp) = try await session.data(for: dlFin)
        XCTAssertEqual((dlFinResp as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [dlDone], timeout: 5)
        XCTAssertEqual(downloadedCount, Int64(total))
        XCTAssertEqual(assembled, payload)
    }
}
