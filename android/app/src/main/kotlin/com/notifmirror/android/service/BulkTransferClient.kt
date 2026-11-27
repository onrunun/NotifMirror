package com.notifmirror.android.service

import com.notifmirror.android.security.pinnedSslSocketFactory
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import javax.net.ssl.HostnameVerifier
import kotlin.concurrent.withLock

/**
 * High-speed, stall-resistant TLS HTTP/1.1 client for bulk file transfers.
 *
 * Uses parallel short-lived `Connection: close` chunk/Range requests with
 * fast per-chunk timeout detection, automatic retry, and recursive chunk-split
 * recovery so transfers stay fast even across Wi-Fi APs that stall long-lived
 * STA-to-STA TCP flows, while remaining 100% backward-compatible with
 * single-stream endpoints for small files or older peers.
 */
internal class BulkTransferClient(serverFp: String) {

    private val streamClient: OkHttpClient
    private val chunkClient: OkHttpClient

    init {
        val (factory, trustManager) = pinnedSslSocketFactory(serverFp)
        val verifier = HostnameVerifier { _, _ -> true }
        streamClient = OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_1_1))
            .connectionPool(ConnectionPool(MAX_IDLE_CONNECTIONS, KEEP_ALIVE_SECONDS, TimeUnit.SECONDS))
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(IO_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(IO_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .sslSocketFactory(factory, trustManager)
            .hostnameVerifier(verifier)
            .build()

        val chunkDispatcher = Dispatcher().apply {
            maxRequests = MAX_CONCURRENT_REQUESTS
            maxRequestsPerHost = MAX_REQUESTS_PER_HOST
        }
        chunkClient = OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_1_1))
            .dispatcher(chunkDispatcher)
            // Fresh TCP 5-tuple per chunk avoids per-flow router/AP stalls while
            // sharing SSLContext TLS 1.3 session cache for fast resumption.
            .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
            .connectTimeout(CHUNK_CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(CHUNK_IO_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(CHUNK_IO_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(CHUNK_CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .sslSocketFactory(factory, trustManager)
            .hostnameVerifier(verifier)
            .build()
    }

    private val workerPool: ExecutorService = Executors.newFixedThreadPool(PARALLEL_WORKERS) { runnable ->
        Thread(runnable, "bulk-worker").apply { isDaemon = true }
    }

    private val activeTransfers = ConcurrentHashMap<String, TransferHandle>()

    fun cancel(id: String) {
        activeTransfers.remove(id)?.cancel()
    }

    fun cancelAll() {
        val snapshot = activeTransfers.values.toList()
        activeTransfers.clear()
        snapshot.forEach { it.cancel() }
    }

    fun uploadStream(
        host: String,
        port: Int,
        secret: String,
        id: String,
        contentLength: Long,
        openInput: () -> InputStream?,
        onProgress: ((Long) -> Unit)? = null
    ) {
        val endpoint = Endpoint(host, port, secret, id)
        val handle = TransferHandle()
        activeTransfers[id] = handle
        try {
            if (contentLength in 0L..UPLOAD_CHUNK_SIZE.toLong()) {
                uploadSingleShot(endpoint, contentLength, openInput, handle, onProgress)
            } else {
                ChunkedUploader(chunkClient, workerPool, endpoint, handle, onProgress).run(openInput)
            }
        } finally {
            activeTransfers.remove(id, handle)
        }
    }

    fun downloadToStream(
        host: String,
        port: Int,
        secret: String,
        id: String,
        out: OutputStream,
        onProgress: ((Long) -> Unit)? = null
    ): Long {
        val endpoint = Endpoint(host, port, secret, id)
        val handle = TransferHandle()
        activeTransfers[id] = handle
        try {
            return RangeDownloader(chunkClient, workerPool, endpoint, handle, onProgress).run(out)
        } finally {
            activeTransfers.remove(id, handle)
        }
    }

    private fun uploadSingleShot(
        endpoint: Endpoint,
        contentLength: Long,
        openInput: () -> InputStream?,
        handle: TransferHandle,
        onProgress: ((Long) -> Unit)?
    ) {
        val body = StreamingFileBody(contentLength, openInput, onProgress)
        val request = Request.Builder()
            .url("https://${endpoint.host}:${endpoint.port}/upload/${endpoint.id}")
            .header("Authorization", "Bearer ${endpoint.secret}")
            .header("Connection", "close")
            .post(body)
            .build()
        executeCall(streamClient, request, handle) { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        }
    }

    private class TransferHandle {
        val cancelled = AtomicBoolean(false)
        val calls: MutableSet<Call> = ConcurrentHashMap.newKeySet()

        fun cancel() {
            cancelled.set(true)
            val snapshot = calls.toList()
            calls.clear()
            snapshot.forEach { it.cancel() }
        }

        fun checkActive() {
            if (cancelled.get()) throw IOException("Transfer cancelled")
        }
    }

    private data class Endpoint(
        val host: String,
        val port: Int,
        val secret: String,
        val id: String
    )

    private class ChunkedUploader(
        private val chunkClient: OkHttpClient,
        private val workerPool: ExecutorService,
        private val endpoint: Endpoint,
        private val handle: TransferHandle,
        private val onProgress: ((Long) -> Unit)?
    ) {
        private val permits = Semaphore(MAX_IN_FLIGHT_UPLOAD)
        private val firstError = AtomicReference<IOException?>(null)
        private val uploaded = AtomicLong(0L)
        private val lastTick = AtomicLong(System.nanoTime())
        private val pending = AtomicLong(1L)
        private val doneLatch = CountDownLatch(1)

        fun run(openInput: () -> InputStream?) {
            val input = openInput() ?: throw IOException("cannot open input stream")
            var totalRead = 0L
            try {
                totalRead = produceChunks(input)
            } catch (e: IOException) {
                recordFailure(e)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                recordFailure(IOException("Transfer interrupted", e))
            } finally {
                if (pending.decrementAndGet() == 0L) doneLatch.countDown()
            }

            doneLatch.await()
            firstError.get()?.let { throw it }
            handle.checkActive()

            finishTransfer(chunkClient, endpoint, "upload", totalRead, handle)
            onProgress?.invoke(totalRead)
        }

        private fun produceChunks(input: InputStream): Long {
            var totalRead = 0L
            input.use { stream ->
                var hasMore = true
                while (hasMore && !handle.cancelled.get() && firstError.get() == null) {
                    val buf = readUpTo(stream, UPLOAD_CHUNK_SIZE)
                    if (buf.isEmpty()) {
                        hasMore = false
                    } else {
                        val offset = totalRead
                        totalRead += buf.size
                        dispatchChunk(offset, buf)
                    }
                }
            }
            return totalRead
        }

        private fun dispatchChunk(offset: Long, data: ByteArray) {
            permits.acquire()
            if (handle.cancelled.get() || firstError.get() != null) {
                permits.release()
                return
            }
            pending.incrementAndGet()
            workerPool.execute {
                try {
                    if (!handle.cancelled.get() && firstError.get() == null) {
                        uploadChunkWithRetry(offset, data)
                        val totalNow = uploaded.addAndGet(data.size.toLong())
                        emitProgress(totalNow, lastTick, onProgress)
                    }
                } catch (e: IOException) {
                    recordFailure(e)
                } finally {
                    permits.release()
                    if (pending.decrementAndGet() == 0L) doneLatch.countDown()
                }
            }
        }

        private fun recordFailure(err: IOException) {
            if (firstError.compareAndSet(null, err)) {
                handle.cancel()
            }
        }

        private fun uploadChunkWithRetry(offset: Long, data: ByteArray) {
            var attempt = 0
            var lastError: IOException? = null
            while (attempt < MAX_RETRIES) {
                handle.checkActive()
                try {
                    putChunk(offset, data)
                    return
                } catch (e: IOException) {
                    lastError = e
                    attempt++
                    handle.checkActive()
                    if (data.size > MIN_UPLOAD_SPLIT_SIZE) {
                        splitAndUpload(offset, data)
                        return
                    }
                    backoff(attempt)
                }
            }
            throw lastError ?: IOException("Chunk upload failed at offset $offset")
        }

        private fun splitAndUpload(offset: Long, data: ByteArray) {
            val mid = data.size / 2
            uploadChunkWithRetry(offset, data.copyOfRange(0, mid))
            uploadChunkWithRetry(offset + mid, data.copyOfRange(mid, data.size))
        }

        private fun putChunk(offset: Long, data: ByteArray) {
            val request = Request.Builder()
                .url("https://${endpoint.host}:${endpoint.port}/upload/${endpoint.id}")
                .header("Authorization", "Bearer ${endpoint.secret}")
                .header("X-Chunk-Offset", offset.toString())
                .header("Connection", "close")
                .put(data.toRequestBody(OCTET_STREAM, 0, data.size))
                .build()
            executeCall(chunkClient, request, handle) { response ->
                if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            }
        }
    }

    private class RangeDownloader(
        private val chunkClient: OkHttpClient,
        private val workerPool: ExecutorService,
        private val endpoint: Endpoint,
        private val handle: TransferHandle,
        private val onProgress: ((Long) -> Unit)?
    ) {
        private val lock = ReentrantLock()
        private val readySignal = lock.newCondition()
        private val readyChunks = HashMap<Int, ByteArray>()
        private val firstError = AtomicReference<IOException?>(null)
        private val lastTick = AtomicLong(System.nanoTime())

        fun run(out: OutputStream): Long {
            val probe = fetchInitialProbe(out)
            if (probe.legacyCopied >= 0L) return probe.legacyCopied

            val head = probe.firstBytes
            if (head.isNotEmpty()) {
                out.write(head)
                onProgress?.invoke(head.size.toLong())
            }
            if (head.size.toLong() >= probe.totalSize) {
                out.flush()
                finishTransfer(chunkClient, endpoint, "download", probe.totalSize, handle)
                return probe.totalSize
            }

            val written = downloadRemaining(head.size.toLong(), probe.totalSize, out)
            out.flush()
            onProgress?.invoke(written)
            finishTransfer(chunkClient, endpoint, "download", written, handle)
            return written
        }

        private data class ProbeResult(
            val legacyCopied: Long = -1L,
            val firstBytes: ByteArray = ByteArray(0),
            val totalSize: Long = 0L
        )

        private fun fetchInitialProbe(out: OutputStream): ProbeResult {
            val request = Request.Builder()
                .url("https://${endpoint.host}:${endpoint.port}/download/${endpoint.id}")
                .header("Authorization", "Bearer ${endpoint.secret}")
                .header("Range", "bytes=0-${DOWNLOAD_CHUNK_SIZE - 1}")
                .header("Connection", "close")
                .get()
                .build()

            var result = ProbeResult()
            executeCall(chunkClient, request, handle) { response ->
                result = parseProbeResponse(response, out)
            }
            return result
        }

        private fun parseProbeResponse(response: Response, out: OutputStream): ProbeResult {
            if (response.code == HTTP_OK) {
                val body = response.body ?: throw IOException("empty response body")
                return ProbeResult(legacyCopied = copyStream(body.byteStream(), out, onProgress))
            }
            val total = if (response.code == HTTP_PARTIAL) {
                parseContentRangeTotal(response.header("Content-Range"))
            } else {
                null
            }
            val validTotal = total ?: throw IOException("unexpected range response HTTP ${response.code}")
            val bytes = response.body?.bytes() ?: ByteArray(0)
            return ProbeResult(firstBytes = bytes, totalSize = validTotal)
        }

        private fun downloadRemaining(startOffset: Long, totalSize: Long, out: OutputStream): Long {
            val remaining = totalSize - startOffset
            val chunkCount = ((remaining + DOWNLOAD_CHUNK_SIZE - 1) / DOWNLOAD_CHUNK_SIZE).toInt()
            var nextWriteIdx = 0
            var nextDispatchIdx = 0
            var written = startOffset

            while (nextWriteIdx < chunkCount) {
                nextDispatchIdx = dispatchWindow(nextDispatchIdx, nextWriteIdx, chunkCount, startOffset, totalSize)
                val ready = awaitContiguousChunks(nextWriteIdx)
                firstError.get()?.let { throw it }
                handle.checkActive()
                for (chunk in ready) {
                    out.write(chunk)
                    written += chunk.size
                    nextWriteIdx++
                    emitProgress(written, lastTick, onProgress)
                }
            }
            return written
        }

        private fun dispatchWindow(
            fromIdx: Int,
            writeIdx: Int,
            chunkCount: Int,
            startOffset: Long,
            totalSize: Long
        ): Int {
            var idx = fromIdx
            while (idx < chunkCount && idx - writeIdx < REORDER_WINDOW) {
                val chunkIdx = idx++
                val rangeStart = startOffset + chunkIdx.toLong() * DOWNLOAD_CHUNK_SIZE
                val rangeEnd = minOf(rangeStart + DOWNLOAD_CHUNK_SIZE - 1, totalSize - 1)
                workerPool.execute { fetchWorker(chunkIdx, rangeStart, rangeEnd) }
            }
            return idx
        }

        private fun fetchWorker(chunkIdx: Int, rangeStart: Long, rangeEnd: Long) {
            if (handle.cancelled.get() || firstError.get() != null) return
            try {
                val bytes = fetchRangeWithRetry(rangeStart, rangeEnd)
                lock.withLock {
                    readyChunks[chunkIdx] = bytes
                    readySignal.signalAll()
                }
            } catch (e: IOException) {
                if (firstError.compareAndSet(null, e)) handle.cancel()
                lock.withLock { readySignal.signalAll() }
            }
        }

        private fun awaitContiguousChunks(startIdx: Int): List<ByteArray> {
            val drained = ArrayList<ByteArray>()
            lock.withLock {
                while (!readyChunks.containsKey(startIdx) &&
                    firstError.get() == null &&
                    !handle.cancelled.get()
                ) {
                    readySignal.await(SIGNAL_WAIT_MS, TimeUnit.MILLISECONDS)
                }
                var cursor = startIdx
                while (readyChunks.containsKey(cursor)) {
                    drained.add(readyChunks.remove(cursor)!!)
                    cursor++
                }
            }
            return drained
        }

        private fun fetchRangeWithRetry(start: Long, end: Long): ByteArray {
            val expectedLen = (end - start + 1).toInt()
            var attempt = 0
            var lastError: IOException? = null
            while (attempt < MAX_RETRIES) {
                handle.checkActive()
                try {
                    return getRangeBytes(start, end, expectedLen)
                } catch (e: IOException) {
                    lastError = e
                    attempt++
                    handle.checkActive()
                    if (expectedLen > MIN_DOWNLOAD_SPLIT_SIZE) {
                        val mid = start + (end - start) / 2
                        return fetchRangeWithRetry(start, mid) + fetchRangeWithRetry(mid + 1, end)
                    }
                    backoff(attempt)
                }
            }
            throw lastError ?: IOException("Range download failed at $start-$end")
        }

        private fun getRangeBytes(start: Long, end: Long, expectedLen: Int): ByteArray {
            val request = Request.Builder()
                .url("https://${endpoint.host}:${endpoint.port}/download/${endpoint.id}")
                .header("Authorization", "Bearer ${endpoint.secret}")
                .header("Range", "bytes=$start-$end")
                .header("Connection", "close")
                .get()
                .build()
            var bytes = ByteArray(0)
            executeCall(chunkClient, request, handle) { response ->
                val okStatus = response.code == HTTP_PARTIAL || response.code == HTTP_OK
                val body = if (okStatus) response.body?.bytes() else null
                if (body == null || body.size != expectedLen) {
                    throw IOException("range read failed HTTP ${response.code} len=${body?.size}/$expectedLen")
                }
                bytes = body
            }
            return bytes
        }
    }

    private class StreamingFileBody(
        private val length: Long,
        private val openInput: () -> InputStream?,
        private val onProgress: ((Long) -> Unit)?
    ) : RequestBody() {
        override fun contentType() = OCTET_STREAM
        override fun contentLength(): Long = length
        override fun isOneShot(): Boolean = true

        override fun writeTo(sink: BufferedSink) {
            val stream = openInput() ?: throw IOException("cannot open input stream")
            val buffer = ByteArray(STREAM_BUFFER_SIZE)
            var sent = 0L
            var lastTick = System.nanoTime()
            stream.use { input ->
                while (true) {
                    val n = input.read(buffer)
                    if (n <= 0) break
                    sink.write(buffer, 0, n)
                    sent += n
                    val now = System.nanoTime()
                    if (onProgress != null && now - lastTick >= PROGRESS_INTERVAL_NS) {
                        lastTick = now
                        onProgress(sent)
                    }
                }
            }
            sink.flush()
            onProgress?.invoke(sent)
        }
    }

    companion object {
        private const val STREAM_BUFFER_SIZE = 256 * 1024
        private const val UPLOAD_CHUNK_SIZE = 1024 * 1024
        private const val MIN_UPLOAD_SPLIT_SIZE = 32 * 1024
        private const val DOWNLOAD_CHUNK_SIZE = 512 * 1024
        private const val MIN_DOWNLOAD_SPLIT_SIZE = 16 * 1024
        private const val PARALLEL_WORKERS = 4
        private const val MAX_IN_FLIGHT_UPLOAD = 6
        private const val REORDER_WINDOW = 8
        private const val MAX_CONCURRENT_REQUESTS = 16
        private const val MAX_REQUESTS_PER_HOST = 12
        private const val MAX_RETRIES = 4
        private const val FINISH_RETRIES = 3
        private const val RETRY_BACKOFF_MS = 80L
        private const val SIGNAL_WAIT_MS = 250L
        private const val PROGRESS_INTERVAL_NS = 100_000_000L
        private const val MAX_IDLE_CONNECTIONS = 4
        private const val KEEP_ALIVE_SECONDS = 30L
        private const val CONNECT_TIMEOUT_SECONDS = 15L
        private const val IO_TIMEOUT_SECONDS = 60L
        private const val CHUNK_CONNECT_TIMEOUT_SECONDS = 4L
        private const val CHUNK_IO_TIMEOUT_SECONDS = 4L
        private const val CHUNK_CALL_TIMEOUT_SECONDS = 12L
        private const val HTTP_OK = 200
        private const val HTTP_PARTIAL = 206
        private val OCTET_STREAM = "application/octet-stream".toMediaType()

        private fun finishTransfer(
            chunkClient: OkHttpClient,
            endpoint: Endpoint,
            kind: String,
            totalBytes: Long,
            handle: TransferHandle
        ) {
            var attempt = 0
            var lastError: IOException? = null
            while (attempt < FINISH_RETRIES) {
                val request = Request.Builder()
                    .url("https://${endpoint.host}:${endpoint.port}/$kind/${endpoint.id}/finish")
                    .header("Authorization", "Bearer ${endpoint.secret}")
                    .header("X-Total-Bytes", totalBytes.toString())
                    .header("Connection", "close")
                    .post(ByteArray(0).toRequestBody(OCTET_STREAM, 0, 0))
                    .build()
                try {
                    executeCall(chunkClient, request, handle) { response ->
                        if (!response.isSuccessful) throw IOException("finish HTTP ${response.code}")
                    }
                    return
                } catch (e: IOException) {
                    lastError = e
                    attempt++
                    handle.checkActive()
                    backoff(attempt)
                }
            }
            throw lastError ?: IOException("finish failed")
        }

        private inline fun executeCall(
            httpClient: OkHttpClient,
            request: Request,
            handle: TransferHandle,
            block: (Response) -> Unit
        ) {
            handle.checkActive()
            val call = httpClient.newCall(request)
            handle.calls.add(call)
            try {
                if (handle.cancelled.get()) {
                    call.cancel()
                    handle.checkActive()
                }
                call.execute().use(block)
            } finally {
                handle.calls.remove(call)
            }
        }

        private fun backoff(attempt: Int) {
            if (attempt < MAX_RETRIES) {
                try {
                    Thread.sleep(RETRY_BACKOFF_MS * attempt)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }

        private fun readUpTo(stream: InputStream, maxBytes: Int): ByteArray {
            val buf = ByteArray(maxBytes)
            var filled = 0
            while (filled < maxBytes) {
                val n = stream.read(buf, filled, maxBytes - filled)
                if (n <= 0) break
                filled += n
            }
            return if (filled == maxBytes) buf else buf.copyOf(filled)
        }

        private fun emitProgress(
            bytes: Long,
            lastTick: AtomicLong,
            onProgress: ((Long) -> Unit)?
        ) {
            if (onProgress == null) return
            val now = System.nanoTime()
            val prev = lastTick.get()
            if (now - prev >= PROGRESS_INTERVAL_NS && lastTick.compareAndSet(prev, now)) {
                onProgress(bytes)
            }
        }

        private fun parseContentRangeTotal(header: String?): Long? {
            if (header == null) return null
            val slash = header.lastIndexOf('/')
            if (slash < 0 || slash + 1 >= header.length) return null
            return header.substring(slash + 1).trim().toLongOrNull()
        }

        private fun copyStream(
            input: InputStream,
            out: OutputStream,
            onProgress: ((Long) -> Unit)?
        ): Long {
            val buffer = ByteArray(STREAM_BUFFER_SIZE)
            var copied = 0L
            var lastTick = System.nanoTime()
            input.use { stream ->
                while (true) {
                    val n = stream.read(buffer)
                    if (n <= 0) break
                    out.write(buffer, 0, n)
                    copied += n
                    val now = System.nanoTime()
                    if (onProgress != null && now - lastTick >= PROGRESS_INTERVAL_NS) {
                        lastTick = now
                        onProgress(copied)
                    }
                }
            }
            out.flush()
            onProgress?.invoke(copied)
            return copied
        }
    }
}
