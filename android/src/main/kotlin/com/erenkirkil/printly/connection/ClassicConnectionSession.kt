package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.os.Handler
import android.os.Looper
import com.erenkirkil.printly.util.WireCodes
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Per-device RFCOMM (SPP) session. The blocking `BluetoothSocket.connect()`
 * call runs on a dedicated single-thread executor — if we ever run it on the
 * main thread we'd stall the UI for multiple seconds while the stack
 * negotiates the channel.
 *
 * A soft timeout is implemented by scheduling a `socket.close()` after the
 * requested duration; closing the socket mid-connect causes the blocking
 * `connect()` to throw IOException, which we surface as a failure.
 *
 * After a successful connect a daemon reader thread blocks on the input stream
 * so a remote drop (printer powered off, out of range) is detected and reported
 * via [onDisconnected] instead of silently leaving the link marked connected.
 */
internal class ClassicConnectionSession(
    private val adapter: BluetoothAdapter,
    private val device: BluetoothDevice,
) {
    @Volatile private var socket: BluetoothSocket? = null
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val timeoutHandler = Handler(Looper.getMainLooper())
    private var connectTimeoutRunnable: Runnable? = null

    // The connect outcome and the timeout race to settle the attempt; whichever
    // wins this CAS reports the result, the loser becomes a no-op. This prevents
    // a timeout's socket-close from landing just after a successful connect()
    // and reporting CONNECTED on an already-closed socket.
    private val settled = AtomicBoolean(false)
    @Volatile private var resultCb: ((Throwable?) -> Unit)? = null

    // Session teardown guard, shared with the reader thread so an intentional
    // close() is not mistaken for a remote drop.
    private val closed = AtomicBoolean(false)
    @Volatile private var connectedFlag = false
    @Volatile private var onDisconnected: (() -> Unit)? = null
    @Volatile private var readerThread: Thread? = null

    /** Whether a link is currently open (connected and not torn down). */
    fun isConnected(): Boolean = connectedFlag && !closed.get()

    /**
     * Opens the link. [onResult] fires once with `null` on success or the
     * failure cause. [onDisconnected] fires at most once if the link drops
     * remotely after a successful connect (never for an intentional [close]).
     */
    @SuppressLint("MissingPermission")
    fun connect(
        timeoutMs: Long?,
        onResult: (Throwable?) -> Unit,
        onDisconnected: () -> Unit,
    ) {
        this.resultCb = onResult
        this.onDisconnected = onDisconnected
        scheduleConnectTimeout(timeoutMs)
        io.submit {
            try {
                try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
                val sock = openSocket()
                // Only start the reader if we (not the timeout) settled success.
                if (finishConnect(null)) startReader(sock)
            } catch (e: Throwable) {
                finishConnect(e)
            }
        }
    }

    /**
     * Connects the SPP socket, retrying once over the reflective channel-1
     * socket if the standard service-record connect fails — the common
     * workaround for a printer still holding a stale channel (e.g. after the
     * app was killed while connected).
     */
    @SuppressLint("MissingPermission")
    private fun openSocket(): BluetoothSocket {
        val primary = device.createRfcommSocketToServiceRecord(SPP_UUID)
        socket = primary
        try {
            primary.connect()
            return primary
        } catch (first: IOException) {
            if (settled.get()) throw first // timeout already closed us; do not retry
            try { primary.close() } catch (_: IOException) {}
            val fallback = createReflectiveSocket() ?: throw first
            socket = fallback // assign before connect so the timeout can interrupt it
            try {
                fallback.connect()
                return fallback
            } catch (_: IOException) {
                try { fallback.close() } catch (_: IOException) {}
                throw first
            }
        }
    }

    private fun createReflectiveSocket(): BluetoothSocket? = try {
        val method = device.javaClass.getMethod(
            "createRfcommSocket",
            Int::class.javaPrimitiveType,
        )
        method.invoke(device, 1) as BluetoothSocket
    } catch (_: Throwable) {
        null
    }

    private fun startReader(sock: BluetoothSocket) {
        val t = Thread {
            try {
                val input = sock.inputStream
                val buffer = ByteArray(256)
                while (!closed.get()) {
                    if (input.read(buffer) < 0) break // EOF → remote closed the link
                }
            } catch (_: IOException) {
                // Socket closed or link dropped.
            }
            // Report a drop only if we didn't tear the session down ourselves.
            if (!closed.getAndSet(true)) notifyDropped()
        }
        t.isDaemon = true
        readerThread = t
        t.start()
    }

    private fun notifyDropped() {
        safeClose()
        val cb = onDisconnected
        onDisconnected = null
        cb?.invoke()
    }

    private fun finishConnect(error: Throwable?): Boolean {
        if (!settled.compareAndSet(false, true)) {
            // Lost the race to the timeout. If we still opened a socket, close
            // it so a late success does not leak an orphaned connection.
            if (error == null) safeClose()
            return false
        }
        cancelConnectTimeout()
        if (error != null) safeClose() else connectedFlag = true
        val cb = resultCb
        resultCb = null
        cb?.invoke(error)
        return error == null
    }

    /**
     * Writes [bytes] to the open RFCOMM stream, bounded by [WRITE_TIMEOUT_MS].
     * Rejects with `not_connected` before the link is up. The blocking write
     * runs on the same single-thread executor as [connect]; a main-thread
     * watchdog closes the socket to unblock a stalled write (full buffer /
     * dead link) and reports `write_timeout`. [onResult] fires exactly once.
     */
    fun write(bytes: ByteArray, onResult: (Throwable?) -> Unit) {
        // Reject before the link is up (mirrors the GATT session). Without
        // this gate a write queued behind an in-flight connect would start its
        // watchdog immediately, and the watchdog's safeClose() could tear the
        // socket down mid-connect and abort the connect attempt.
        if (!isConnected()) {
            onResult(IOException(WireCodes.Reasons.NOT_CONNECTED))
            return
        }
        val done = AtomicBoolean(false)
        val watchdog = Runnable {
            if (done.compareAndSet(false, true)) {
                safeClose() // unblock the stuck write and mark the link dead
                onResult(IOException(WireCodes.Reasons.WRITE_TIMEOUT))
            }
        }
        timeoutHandler.postDelayed(watchdog, WRITE_TIMEOUT_MS)
        try {
            io.submit {
                try {
                    val sock = socket ?: throw IOException(WireCodes.Reasons.NOT_CONNECTED)
                    sock.outputStream.write(bytes)
                    sock.outputStream.flush()
                    settle(done, watchdog) { onResult(null) }
                } catch (e: Throwable) {
                    settle(done, watchdog) { onResult(e) }
                }
            }
        } catch (_: RejectedExecutionException) {
            settle(done, watchdog) { onResult(IOException(WireCodes.Reasons.NOT_CONNECTED)) }
        }
    }

    private inline fun settle(
        done: AtomicBoolean,
        watchdog: Runnable,
        report: () -> Unit,
    ) {
        if (done.compareAndSet(false, true)) {
            timeoutHandler.removeCallbacks(watchdog)
            report()
        }
    }

    fun close() {
        closed.set(true)
        cancelConnectTimeout()
        safeClose()
        readerThread?.interrupt()
        io.shutdownNow()
    }

    private fun safeClose() {
        try { socket?.close() } catch (_: IOException) {}
        socket = null
    }

    private fun scheduleConnectTimeout(timeoutMs: Long?) {
        cancelConnectTimeout()
        if (timeoutMs == null || timeoutMs <= 0) return
        val r = Runnable {
            if (settled.compareAndSet(false, true)) {
                safeClose()
                val cb = resultCb
                resultCb = null
                cb?.invoke(IOException(WireCodes.Reasons.CONNECT_TIMEOUT))
            }
        }
        connectTimeoutRunnable = r
        timeoutHandler.postDelayed(r, timeoutMs)
    }

    private fun cancelConnectTimeout() {
        connectTimeoutRunnable?.let { timeoutHandler.removeCallbacks(it) }
        connectTimeoutRunnable = null
    }

    private companion object {
        // Well-known Serial Port Profile UUID; every thermal printer that
        // speaks RFCOMM advertises this service record.
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        // Upper bound for a single RFCOMM write. Text-first jobs flush in
        // milliseconds; this only fires when the link is dead or the buffer is
        // wedged.
        const val WRITE_TIMEOUT_MS = 10_000L
    }
}
