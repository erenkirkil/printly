package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Per-device RFCOMM (SPP) session. The blocking `BluetoothSocket.connect()`
 * call runs on a dedicated single-thread executor — if we ever run it on the
 * main thread we'd stall the UI for multiple seconds while the stack
 * negotiates the channel.
 *
 * A soft timeout is implemented by scheduling a `socket.close()` after the
 * requested duration; closing the socket mid-connect causes the blocking
 * `connect()` to throw IOException, which we surface as a failure.
 */
internal class ClassicConnectionSession(
    private val adapter: BluetoothAdapter,
    private val device: BluetoothDevice,
) {
    @Volatile private var socket: BluetoothSocket? = null
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val timeoutHandler = Handler(Looper.getMainLooper())
    private var timeoutRunnable: Runnable? = null

    @SuppressLint("MissingPermission")
    fun connect(timeoutMs: Long?, onResult: (Throwable?) -> Unit) {
        scheduleTimeout(timeoutMs)
        io.submit {
            try {
                try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
                val sock = device.createRfcommSocketToServiceRecord(SPP_UUID)
                socket = sock
                sock.connect()
                cancelTimeout()
                onResult(null)
            } catch (e: Throwable) {
                cancelTimeout()
                safeClose()
                onResult(e)
            }
        }
    }

    fun close() {
        cancelTimeout()
        safeClose()
        io.shutdownNow()
    }

    private fun safeClose() {
        try { socket?.close() } catch (_: IOException) {}
        socket = null
    }

    private fun scheduleTimeout(timeoutMs: Long?) {
        cancelTimeout()
        if (timeoutMs == null || timeoutMs <= 0) return
        val r = Runnable { safeClose() }
        timeoutRunnable = r
        timeoutHandler.postDelayed(r, timeoutMs)
    }

    private fun cancelTimeout() {
        timeoutRunnable?.let { timeoutHandler.removeCallbacks(it) }
        timeoutRunnable = null
    }

    private companion object {
        // Well-known Serial Port Profile UUID; every thermal printer that
        // speaks RFCOMM advertises this service record.
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
