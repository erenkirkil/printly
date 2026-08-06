package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.erenkirkil.printly.util.WireCodes
import java.io.IOException
import java.util.UUID

/**
 * Per-device GATT session. Always opened with `autoConnect=false` and the
 * explicit LE transport — autoConnect is a background mode that can delay
 * the first connection attempt for minutes, which would mask transient
 * failures from the user.
 *
 * The session only reports [onConnected] once the link is up **and** services
 * are discovered **and** a writable characteristic is resolved — i.e. the link
 * is actually usable for printing. Any pre-ready failure (connect timeout, GATT
 * error, discovery failure, no writable characteristic) reports [onFailed]; a
 * remote drop after ready reports [onDisconnected]. A soft [connect] timeout
 * guards against `connectGatt` never invoking its callback (the GATT-133 /
 * silent-stall case) which would otherwise wedge the UI in "connecting".
 *
 * All session state is confined to the main thread: `BluetoothGattCallback`
 * fires on binder-pool threads, so every callback body hops onto the main
 * handler before touching state — matching the coordinator's style and
 * removing any need for locks or volatile fields.
 *
 * Writes are split to fit the negotiated ATT MTU (requested as soon as the
 * link connects; the spec default applies until — and unless — the grant
 * arrives) and sent one chunk at a time, each gated on the previous
 * `onCharacteristicWrite` acknowledgement and bounded by a per-chunk watchdog
 * so a stalled printer cannot hang the write forever.
 *
 * `close()` is idempotent so it can safely be called from the callback, the
 * timeout, and the coordinator without leaking file descriptors.
 */
internal class GattConnectionSession(
    private val appContext: Context,
    private val device: BluetoothDevice,
) {
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var writeType: Int = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
    private var closed = false

    private val handler = Handler(Looper.getMainLooper())

    // Connect-phase arbitration: connectSettled flips on the first of
    // ready/failed/timeout; ready records that onConnected fired;
    // disconnectRequested marks a user-initiated teardown so isReady() cannot
    // report a usable link while the stack is still delivering callbacks.
    private var connectSettled = false
    private var ready = false
    private var disconnectRequested = false
    private var disconnectReported = false
    private var connectTimeout: Runnable? = null

    // Granted ATT MTU; stays at the spec default until onMtuChanged fires.
    private var mtu = DEFAULT_MTU

    // Android's GATT stack runs ONE client operation at a time. Issuing
    // requestMtu() and discoverServices() back-to-back silently drops the
    // discovery request on some stacks (observed on Android 11:
    // discoverServices() returns true but onServicesDiscovered never fires,
    // so connect dies on the soft timeout). Discovery is therefore chained
    // after the MTU exchange settles; the fallback timer covers peripherals
    // whose stack never delivers onMtuChanged.
    private var discoveryStarted = false
    private var mtuFallback: Runnable? = null

    /** Whether the link is up and a writable characteristic is resolved. */
    fun isReady(): Boolean = ready && !closed && !disconnectRequested

    private var onConnectedCb: (() -> Unit)? = null
    private var onFailedCb: ((String) -> Unit)? = null
    private var onDisconnectedCb: (() -> Unit)? = null

    private var pendingChunks: ArrayDeque<ByteArray>? = null
    private var pendingResult: ((Throwable?) -> Unit)? = null
    private var busyRetries = 0
    private var writeWatchdog: Runnable? = null

    private enum class SendResult { SENT, BUSY, FAILED }

    /**
     * Opens the link. Exactly one of [onConnected]/[onFailed] fires for the
     * connect attempt; [onDisconnected] fires at most once if a ready link later
     * drops remotely. A connect that does not become ready within [timeoutMs]
     * fails with `connect_timeout`.
     */
    @SuppressLint("MissingPermission")
    fun connect(
        timeoutMs: Long?,
        onConnected: () -> Unit,
        onFailed: (reason: String) -> Unit,
        onDisconnected: () -> Unit,
    ) {
        this.onConnectedCb = onConnected
        this.onFailedCb = onFailed
        this.onDisconnectedCb = onDisconnected

        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                handler.post { handleConnectionStateChange(g, status, newState) }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                handler.post { handleServicesDiscovered(g, status) }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                handler.post { handleMtuChanged(mtu, status) }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                handler.post { handleCharacteristicWrite(status) }
            }
        }

        if (timeoutMs != null && timeoutMs > 0) {
            val r = Runnable { failConnect(WireCodes.Reasons.CONNECT_TIMEOUT) }
            connectTimeout = r
            handler.postDelayed(r, timeoutMs)
        }
        val g = device.connectGatt(
            appContext,
            /* autoConnect = */ false,
            cb,
            BluetoothDevice.TRANSPORT_LE,
        )
        if (g == null) {
            // The stack refused to hand out a GATT client (adapter off, out
            // of client slots) — fail now instead of waiting for the soft
            // timeout to expire on a connect that never started.
            failConnect(WireCodes.Reasons.CONNECT_FAILED)
            return
        }
        gatt = g
        if (closed) {
            // close() raced the connectGatt call — release the client slot
            // the stack just allocated instead of leaking it.
            try { g.disconnect() } catch (_: Throwable) {}
            try { g.close() } catch (_: Throwable) {}
            gatt = null
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
        when {
            newState == BluetoothGatt.STATE_CONNECTED &&
                status == BluetoothGatt.GATT_SUCCESS -> {
                // Ask for a large MTU so raster payloads move in fewer, bigger
                // chunks, then chain service discovery behind the MTU result —
                // never alongside it (see discoveryStarted above). Readiness
                // still never blocks on the grant: if onMtuChanged never fires
                // the fallback starts discovery with the default MTU.
                val mtuRequested = try {
                    g.requestMtu(REQUESTED_MTU)
                } catch (_: Throwable) {
                    false
                }
                if (mtuRequested) {
                    val r = Runnable { startDiscovery(g) }
                    mtuFallback = r
                    handler.postDelayed(r, MTU_TIMEOUT_MS)
                } else {
                    startDiscovery(g)
                }
            }
            newState == BluetoothGatt.STATE_CONNECTED ->
                failConnect("gatt_status_$status")
            newState == BluetoothGatt.STATE_DISCONNECTED -> {
                if (!connectSettled) {
                    failConnect(
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            "gatt_status_$status"
                        } else {
                            WireCodes.Reasons.DISCONNECTED
                        },
                    )
                } else {
                    reportDisconnect()
                }
            }
        }
    }

    private fun handleServicesDiscovered(g: BluetoothGatt, status: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failConnect("service_discovery_failed")
            return
        }
        resolveWriteCharacteristic(g)
        if (writeChar != null) succeedConnect() else failConnect("no_writable_characteristic")
    }

    private fun handleMtuChanged(grantedMtu: Int, status: Int) {
        cancelMtuFallback()
        if (status == BluetoothGatt.GATT_SUCCESS && grantedMtu > 0) {
            mtu = grantedMtu
        }
        gatt?.let { startDiscovery(it) }
    }

    /** Starts service discovery exactly once per session, no matter whether
     * the MTU callback and the fallback timer race each other. */
    @SuppressLint("MissingPermission")
    private fun startDiscovery(g: BluetoothGatt) {
        if (discoveryStarted || closed) return
        discoveryStarted = true
        val started = try { g.discoverServices() } catch (_: Throwable) { false }
        if (!started) failConnect("service_discovery_failed")
    }

    private fun cancelMtuFallback() {
        mtuFallback?.let { handler.removeCallbacks(it) }
        mtuFallback = null
    }

    private fun handleCharacteristicWrite(status: Int) {
        if (pendingResult == null) return
        cancelWriteWatchdog()
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failWrite(IOException("gatt_write_status_$status"))
            return
        }
        busyRetries = 0
        pendingChunks?.removeFirstOrNull()
        writeNextChunk()
    }

    private fun succeedConnect() {
        if (connectSettled) return
        connectSettled = true
        ready = true
        cancelConnectTimeout()
        onConnectedCb?.invoke()
    }

    private fun failConnect(reason: String) {
        if (connectSettled) return
        connectSettled = true
        cancelConnectTimeout()
        close()
        onFailedCb?.invoke(reason)
    }

    private fun reportDisconnect() {
        if (ready && !disconnectReported) {
            disconnectReported = true
            onDisconnectedCb?.invoke()
        }
    }

    /**
     * Splits [bytes] into MTU-sized chunks and writes them sequentially,
     * bounded by a per-chunk watchdog. Rejects with `not_connected` before the
     * link is up, `not_ready` before a writable characteristic is resolved, and
     * `write_busy` while a previous write is still draining.
     */
    fun write(bytes: ByteArray, onResult: (Throwable?) -> Unit) {
        if (gatt == null) {
            onResult(IOException(WireCodes.Reasons.NOT_CONNECTED))
            return
        }
        if (writeChar == null) {
            onResult(IOException(WireCodes.Reasons.NOT_READY))
            return
        }
        if (pendingResult != null) {
            onResult(IOException(WireCodes.Reasons.WRITE_BUSY))
            return
        }
        if (bytes.isEmpty()) {
            onResult(null)
            return
        }
        // Payload per write is the granted MTU minus the 3-byte ATT header.
        val chunkSize = (mtu - ATT_HEADER_BYTES).coerceAtLeast(1)
        val chunks = ArrayDeque<ByteArray>()
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + chunkSize, bytes.size)
            chunks.add(bytes.copyOfRange(offset, end))
            offset = end
        }
        pendingChunks = chunks
        pendingResult = onResult
        busyRetries = 0
        writeNextChunk()
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        // Flag the teardown first so isReady() cannot report a usable link
        // while the stack is still delivering the final callbacks.
        disconnectRequested = true
        val g = gatt ?: return
        try { g.disconnect() } catch (_: Throwable) {}
    }

    @SuppressLint("MissingPermission")
    fun close() {
        if (closed) return
        closed = true
        cancelConnectTimeout()
        cancelWriteWatchdog()
        cancelMtuFallback()
        failWrite(IOException(WireCodes.Reasons.DISCONNECTED))
        val g = gatt ?: return
        try { g.disconnect() } catch (_: Throwable) {}
        try { g.close() } catch (_: Throwable) {}
        gatt = null
        writeChar = null
    }

    private fun resolveWriteCharacteristic(g: BluetoothGatt) {
        val writable = g.services
            .flatMap { it.characteristics }
            .filter {
                val p = it.properties
                (p and BluetoothGattCharacteristic.PROPERTY_WRITE) != 0 ||
                    (p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
            }
        val chosen = PREFERRED_WRITE_UUIDS
            .firstNotNullOfOrNull { uuid -> writable.firstOrNull { it.uuid == uuid } }
            ?: writable.firstOrNull()
            ?: return
        // Prefer no-response writes: no per-chunk round trip to the printer,
        // and the stack still delivers onCharacteristicWrite once it is ready
        // for the next write, so the ack gating below keeps working.
        writeType = if ((chosen.properties and
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
        ) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        writeChar = chosen
    }

    private fun writeNextChunk() {
        val chunk = pendingChunks?.firstOrNull()
        if (chunk == null) {
            completeWrite()
            return
        }
        val g = gatt
        val ch = writeChar
        if (g == null || ch == null) {
            failWrite(IOException(WireCodes.Reasons.NOT_CONNECTED))
            return
        }
        when (sendChunk(g, ch, chunk)) {
            SendResult.SENT -> scheduleWriteWatchdog()
            SendResult.BUSY ->
                if (busyRetries++ < MAX_BUSY_RETRIES) {
                    handler.postDelayed({ writeNextChunk() }, BUSY_BACKOFF_MS)
                } else {
                    failWrite(IOException(WireCodes.Reasons.WRITE_BUSY))
                }
            SendResult.FAILED -> failWrite(IOException(WireCodes.Reasons.WRITE_FAILED))
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendChunk(
        g: BluetoothGatt,
        ch: BluetoothGattCharacteristic,
        chunk: ByteArray,
    ): SendResult {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            when (g.writeCharacteristic(ch, chunk, writeType)) {
                BluetoothStatusCodes.SUCCESS -> SendResult.SENT
                BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY -> SendResult.BUSY
                else -> SendResult.FAILED
            }
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = writeType
                ch.value = chunk
                // Legacy writeCharacteristic returns false when the stack is
                // busy; treat that as retryable rather than a hard failure.
                if (g.writeCharacteristic(ch)) SendResult.SENT else SendResult.BUSY
            }
        }
    }

    private fun scheduleWriteWatchdog() {
        cancelWriteWatchdog()
        val r = Runnable { failWrite(IOException(WireCodes.Reasons.WRITE_TIMEOUT)) }
        writeWatchdog = r
        handler.postDelayed(r, WRITE_TIMEOUT_MS)
    }

    private fun cancelWriteWatchdog() {
        writeWatchdog?.let { handler.removeCallbacks(it) }
        writeWatchdog = null
    }

    private fun cancelConnectTimeout() {
        connectTimeout?.let { handler.removeCallbacks(it) }
        connectTimeout = null
    }

    private fun completeWrite() = finishWrite(null)

    private fun failWrite(error: Throwable) = finishWrite(error)

    private fun finishWrite(error: Throwable?) {
        cancelWriteWatchdog()
        val cb = pendingResult
        pendingResult = null
        pendingChunks = null
        cb?.invoke(error)
    }

    private companion object {
        // Common thermal BLE-SPP write characteristics, tried before falling
        // back to the first writable characteristic found.
        val PREFERRED_WRITE_UUIDS: List<UUID> = listOf(
            UUID.fromString("0000ff02-0000-1000-8000-00805f9b34fb"),
            UUID.fromString("49535343-8841-43f4-a8d4-ecbe34729bb3"),
            UUID.fromString("0000ffe1-0000-1000-8000-00805f9b34fb"),
        )

        // ATT spec default MTU; in effect until the peripheral grants more.
        const val DEFAULT_MTU = 23

        // Requested MTU: the ATT maximum, so the exchange settles on whatever
        // the peripheral actually supports. Groundwork for the raster sprint —
        // bitmap payloads at 20 bytes per write are unusably slow.
        const val REQUESTED_MTU = 517

        // How long to wait for onMtuChanged before starting discovery anyway
        // (the write path then keeps the spec-default MTU, exactly as before).
        const val MTU_TIMEOUT_MS = 1_500L

        // Per-write ATT overhead: opcode (1 byte) + attribute handle (2 bytes).
        const val ATT_HEADER_BYTES = 3

        // Per-chunk acknowledgement deadline; only fires on a stalled printer.
        const val WRITE_TIMEOUT_MS = 5_000L

        // Transient WRITE_REQUEST_BUSY backoff and bound.
        const val BUSY_BACKOFF_MS = 15L
        const val MAX_BUSY_RETRIES = 8
    }
}
