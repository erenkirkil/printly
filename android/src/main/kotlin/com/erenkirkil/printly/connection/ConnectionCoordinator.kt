package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.util.PermissionChecker
import com.erenkirkil.printly.util.WireCodes

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
    )

    private val entries = mutableMapOf<String, Entry>()

    @SuppressLint("MissingPermission")
    fun connect(payload: Map<String, Any?>, timeoutMs: Long?) {
        if (!PermissionChecker.hasConnect(appContext)) {
            emit(payload, WireCodes.STATE_ERROR, "bluetooth_connect_denied")
            return
        }
        val adapter = currentAdapter() ?: run {
            emit(payload, WireCodes.STATE_ERROR, "bluetooth_unavailable")
            return
        }
        val type = payload["type"] as? Int ?: run {
            emit(payload, WireCodes.STATE_ERROR, "invalid_payload")
            return
        }
        val address = payload["address"] as? String ?: run {
            emit(payload, WireCodes.STATE_ERROR, "invalid_payload")
            return
        }
        val key = keyOf(type, address)
        if (entries.containsKey(key)) {
            // Duplicate call — Dart layer de-dups, this is just defence in
            // depth. Do not open a second native session.
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
                session.connect(timeoutMs) { error ->
                    mainHandler.post {
                        val entry = entries[key] ?: return@post
                        if (error == null) {
                            emit(entry.payload, WireCodes.STATE_CONNECTED, null)
                        } else {
                            entries.remove(key)
                            session.close()
                            emit(
                                entry.payload,
                                WireCodes.STATE_ERROR,
                                error.message ?: "connect_failed",
                            )
                        }
                    }
                }
            }
            WireCodes.TYPE_BLE -> {
                val session = GattConnectionSession(appContext, bt)
                entries[key] = Entry(payload, gatt = session)
                session.connect { status, newState ->
                    mainHandler.post { handleGattState(key, session, status, newState) }
                }
            }
            WireCodes.TYPE_NETWORK -> {
                // Deferred to a later sprint; reject instead of silently hanging.
                emit(payload, WireCodes.STATE_ERROR, "network_not_supported")
            }
            else -> emit(payload, WireCodes.STATE_ERROR, "unsupported_transport")
        }
    }

    fun disconnect(payload: Map<String, Any?>) {
        val type = payload["type"] as? Int ?: return
        val address = payload["address"] as? String ?: return
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
                // Leave the entry in the map — the GATT callback will observe
                // STATE_DISCONNECTED and drive the final cleanup in
                // handleGattState below.
                entry.gatt.disconnect()
            }
        }
    }

    fun detach() {
        for ((_, e) in entries) {
            e.classic?.close()
            e.gatt?.close()
        }
        entries.clear()
    }

    private fun handleGattState(
        key: String,
        session: GattConnectionSession,
        status: Int,
        newState: Int,
    ) {
        val entry = entries[key] ?: return
        when (newState) {
            BluetoothProfile.STATE_CONNECTING ->
                emit(entry.payload, WireCodes.STATE_CONNECTING, null)
            BluetoothProfile.STATE_CONNECTED -> {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    emit(entry.payload, WireCodes.STATE_CONNECTED, null)
                } else {
                    entries.remove(key)
                    session.close()
                    emit(entry.payload, WireCodes.STATE_ERROR, "gatt_status_$status")
                }
            }
            BluetoothProfile.STATE_DISCONNECTING ->
                emit(entry.payload, WireCodes.STATE_DISCONNECTING, null)
            BluetoothProfile.STATE_DISCONNECTED -> {
                entries.remove(key)
                session.close()
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    emit(entry.payload, WireCodes.STATE_ERROR, "gatt_status_$status")
                } else {
                    emit(entry.payload, WireCodes.STATE_DISCONNECTED, null)
                }
            }
        }
    }

    private fun emit(
        payload: Map<String, Any?>,
        state: Int,
        failureReason: String?,
    ) {
        val map = buildMap<String, Any?> {
            put("device", payload)
            put("state", state)
            if (failureReason != null) put("failureReason", failureReason)
        }
        events.emit(map)
    }

    private fun keyOf(type: Int, address: String): String = "$type:$address"

    private fun currentAdapter(): BluetoothAdapter? =
        ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        )?.adapter
}
