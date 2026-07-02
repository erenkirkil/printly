package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.util.PermissionChecker
import com.erenkirkil.printly.util.WireCodes
import java.io.IOException

/**
 * Owns the lifecycle of per-device connection sessions and turns native
 * status into connection-event maps for the event stream handler.
 *
 * The coordinator is intentionally defensive: the Dart-side ConnectionController
 * already serialises connect/disconnect per device, but the coordinator still
 * guards against duplicate sessions and double-close with an internal map
 * keyed by `"type:address"`.
 */
internal class ConnectionCoordinator(
    private val appContext: Context,
    private val events: ConnectionEventsStreamHandler,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private data class Entry(
        val payload: Map<String, Any?>,
        val classic: ClassicConnectionSession? = null,
        val gatt: GattConnectionSession? = null,
    ) {
        // Set by disconnect() so a teardown the user asked for surfaces as a
        // clean DISCONNECTED even when the stack reports it via the failure
        // path, and so connect() can spot an entry that is going away.
        var disconnectRequested: Boolean = false
    }

    private val entries = mutableMapOf<String, Entry>()

    // Observes the adapter turning off so open links are torn down and reported
    // as disconnected instead of silently going stale.
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(
                BluetoothAdapter.EXTRA_STATE,
                BluetoothAdapter.ERROR,
            )
            if (state == BluetoothAdapter.STATE_OFF ||
                state == BluetoothAdapter.STATE_TURNING_OFF
            ) {
                mainHandler.post { onAdapterOff() }
            }
        }
    }
    private var receiverRegistered = false

    init {
        ContextCompat.registerReceiver(
            appContext,
            adapterReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    @SuppressLint("MissingPermission")
    fun connect(payload: Map<String, Any?>, timeoutMs: Long?) {
        if (!PermissionChecker.hasConnect(appContext)) {
            emit(payload, WireCodes.STATE_ERROR, "bluetooth_connect_denied")
            return
        }
        val adapter = currentAdapter() ?: run {
            emit(payload, WireCodes.STATE_ERROR, WireCodes.Reasons.BLUETOOTH_UNAVAILABLE)
            return
        }
        val type = payload[WireCodes.Keys.TYPE] as? Int ?: run {
            emit(payload, WireCodes.STATE_ERROR, "invalid_payload")
            return
        }
        val address = payload[WireCodes.Keys.ADDRESS] as? String ?: run {
            emit(payload, WireCodes.STATE_ERROR, "invalid_payload")
            return
        }
        val key = keyOf(type, address)
        val existing = entries[key]
        if (existing != null) {
            if (existing.disconnectRequested) {
                // The previous session is still tearing down (a GATT entry
                // stays in the map until its disconnect callback or fallback
                // reaps it). Re-emitting CONNECTED here would report a link
                // the stack is about to drop, so reject instead — it is
                // simpler and more predictable than queueing the attempt, and
                // the caller can retry once the DISCONNECTED event lands.
                emit(payload, WireCodes.STATE_ERROR, "disconnect_in_progress")
                return
            }
            // A session already exists. Rather than returning silently — which
            // would leave a hot-restarted Dart side (fresh state, same native
            // process) waiting forever — re-emit the current effective state so
            // it re-hydrates. Also makes a redundant connect idempotent.
            val connected = existing.classic?.isConnected() == true ||
                existing.gatt?.isReady() == true
            emit(
                payload,
                if (connected) WireCodes.STATE_CONNECTED else WireCodes.STATE_CONNECTING,
                null,
            )
            return
        }

        val bt = try {
            adapter.getRemoteDevice(address)
        } catch (e: Throwable) {
            emit(payload, WireCodes.STATE_ERROR, e.message ?: "invalid_address")
            return
        }

        emit(payload, WireCodes.STATE_CONNECTING, null)

        when (type) {
            WireCodes.TYPE_CLASSIC -> {
                val session = ClassicConnectionSession(adapter, bt)
                entries[key] = Entry(payload, classic = session)
                session.connect(
                    timeoutMs,
                    onResult = { error ->
                        mainHandler.post {
                            // Entry gone (disconnect/adapter-off raced us) —
                            // close the orphaned socket instead of leaking it.
                            val entry = entries[key] ?: run {
                                session.close()
                                return@post
                            }
                            if (error == null) {
                                emit(entry.payload, WireCodes.STATE_CONNECTED, null)
                            } else {
                                entries.remove(key)
                                session.close()
                                emit(
                                    entry.payload,
                                    WireCodes.STATE_ERROR,
                                    error.message ?: WireCodes.Reasons.CONNECT_FAILED,
                                )
                            }
                        }
                    },
                    onDisconnected = {
                        mainHandler.post {
                            if (entries.remove(key) != null) {
                                session.close()
                                emit(payload, WireCodes.STATE_DISCONNECTED, null)
                            }
                        }
                    },
                )
            }
            WireCodes.TYPE_BLE -> {
                val session = GattConnectionSession(appContext, bt)
                entries[key] = Entry(payload, gatt = session)
                session.connect(
                    timeoutMs,
                    onConnected = {
                        mainHandler.post {
                            val entry = entries[key] ?: run {
                                session.close()
                                return@post
                            }
                            emit(entry.payload, WireCodes.STATE_CONNECTED, null)
                        }
                    },
                    onFailed = { reason ->
                        mainHandler.post {
                            // Emit only when this handler owned the teardown
                            // (mirrors onDisconnected) — if the entry was
                            // already reaped elsewhere, that path has emitted
                            // the terminal event and a second one would flip
                            // the Dart side back into an error state.
                            val entry = entries.remove(key)
                            if (entry != null) {
                                session.close()
                                if (entry.disconnectRequested) {
                                    // A user-initiated disconnect surfaced via
                                    // the failure path — report it clean.
                                    emit(payload, WireCodes.STATE_DISCONNECTED, null)
                                } else {
                                    emit(payload, WireCodes.STATE_ERROR, reason)
                                }
                            }
                        }
                    },
                    onDisconnected = {
                        mainHandler.post {
                            if (entries.remove(key) != null) {
                                session.close()
                                emit(payload, WireCodes.STATE_DISCONNECTED, null)
                            }
                        }
                    },
                )
            }
            WireCodes.TYPE_NETWORK -> {
                // Deferred to a later sprint; reject instead of silently hanging.
                emit(payload, WireCodes.STATE_ERROR, WireCodes.Reasons.NETWORK_NOT_SUPPORTED)
            }
            else -> emit(payload, WireCodes.STATE_ERROR, "unsupported_transport")
        }
    }

    fun disconnect(payload: Map<String, Any?>) {
        val type = payload[WireCodes.Keys.TYPE] as? Int ?: return
        val address = payload[WireCodes.Keys.ADDRESS] as? String ?: return
        val key = keyOf(type, address)
        val entry = entries[key] ?: run {
            emit(payload, WireCodes.STATE_DISCONNECTED, null)
            return
        }
        emit(entry.payload, WireCodes.STATE_DISCONNECTING, null)

        when {
            entry.classic != null -> {
                entries.remove(key)
                entry.classic.close()
                emit(entry.payload, WireCodes.STATE_DISCONNECTED, null)
            }
            entry.gatt != null -> {
                // Ask the stack to close; the session's onDisconnected callback
                // drives the final cleanup. A fallback timeout force-reaps the
                // entry if the GATT callback never arrives (unreachable device),
                // so the UI can't wedge in "disconnecting".
                entry.disconnectRequested = true
                entry.gatt.disconnect()
                mainHandler.postDelayed({
                    if (entries[key] === entry) {
                        entries.remove(key)
                        entry.gatt.close()
                        emit(entry.payload, WireCodes.STATE_DISCONNECTED, null)
                    }
                }, GATT_DISCONNECT_TIMEOUT_MS)
            }
        }
    }

    /**
     * Writes [bytes] to the session for [payload]'s device, dispatching to the
     * RFCOMM or GATT session. [onResult] is always invoked on the main thread
     * with `null` on success or the failure cause. Rejects with
     * `not_connected` when no session is open.
     */
    fun write(
        payload: Map<String, Any?>,
        bytes: ByteArray,
        onResult: (Throwable?) -> Unit,
    ) {
        val type = payload[WireCodes.Keys.TYPE] as? Int
        val address = payload[WireCodes.Keys.ADDRESS] as? String
        if (type == null || address == null) {
            onResult(IllegalArgumentException("invalid_payload"))
            return
        }
        val key = keyOf(type, address)
        val entry = entries[key]
        when {
            entry == null -> onResult(IOException(WireCodes.Reasons.NOT_CONNECTED))
            entry.classic != null ->
                entry.classic.write(bytes) { error ->
                    mainHandler.post {
                        // A failed RFCOMM write means the link is dead — reconcile
                        // the connection state so the caller isn't left "connected".
                        if (error != null) reconcileDeadLink(key)
                        onResult(error)
                    }
                }
            entry.gatt != null ->
                entry.gatt.write(bytes) { error -> mainHandler.post { onResult(error) } }
            else -> onResult(IOException(WireCodes.Reasons.NOT_CONNECTED))
        }
    }

    /** Whether any connection session is open or in progress. */
    fun hasActiveConnections(): Boolean = entries.isNotEmpty()

    fun detach() {
        if (receiverRegistered) {
            try { appContext.unregisterReceiver(adapterReceiver) } catch (_: Throwable) {}
            receiverRegistered = false
        }
        for ((_, e) in entries) {
            e.classic?.close()
            e.gatt?.close()
        }
        entries.clear()
    }

    /** Tears down a link that failed a write and reports it disconnected once. */
    private fun reconcileDeadLink(key: String) {
        val entry = entries.remove(key) ?: return
        entry.classic?.close()
        entry.gatt?.close()
        emit(entry.payload, WireCodes.STATE_DISCONNECTED, null)
    }

    /** Closes every open session and reports each disconnected on adapter-off. */
    private fun onAdapterOff() {
        if (entries.isEmpty()) return
        val snapshot = entries.toMap()
        entries.clear()
        for ((_, e) in snapshot) {
            e.classic?.close()
            e.gatt?.close()
            emit(e.payload, WireCodes.STATE_DISCONNECTED, null)
        }
    }

    private fun emit(
        payload: Map<String, Any?>,
        state: Int,
        failureReason: String?,
    ) {
        val map = buildMap<String, Any?> {
            put(WireCodes.Keys.DEVICE, payload)
            put(WireCodes.Keys.STATE, state)
            if (failureReason != null) put(WireCodes.Keys.FAILURE_REASON, failureReason)
        }
        events.emit(map)
    }

    private fun keyOf(type: Int, address: String): String = "$type:$address"

    private fun currentAdapter(): BluetoothAdapter? =
        ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        )?.adapter

    private companion object {
        // Fallback deadline to reap a GATT entry when the disconnect callback
        // never arrives (unreachable/powered-off BLE device).
        const val GATT_DISCONNECT_TIMEOUT_MS = 4_000L
    }
}

