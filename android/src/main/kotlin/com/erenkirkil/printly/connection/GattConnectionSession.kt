package com.erenkirkil.printly.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.content.Context
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Per-device GATT session. Always opened with `autoConnect=false` and the
 * explicit LE transport — autoConnect is a background mode that can delay
 * the first connection attempt for minutes, which would mask transient
 * failures from the user.
 *
 * `close()` is idempotent so it can safely be called from both the callback
 * (on remote disconnect) and the coordinator (on explicit disconnect)
 * without leaking file descriptors.
 */
internal class GattConnectionSession(
    private val appContext: Context,
    private val device: BluetoothDevice,
) {
    @Volatile private var gatt: BluetoothGatt? = null
    private val closed = AtomicBoolean(false)

    @SuppressLint("MissingPermission")
    fun connect(onState: (status: Int, newState: Int) -> Unit) {
        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                onState(status, newState)
            }
        }
        gatt = device.connectGatt(
            appContext,
            /* autoConnect = */ false,
            cb,
            BluetoothDevice.TRANSPORT_LE,
        )
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        val g = gatt ?: return
        try { g.disconnect() } catch (_: Throwable) {}
    }

    @SuppressLint("MissingPermission")
    fun close() {
        if (closed.getAndSet(true)) return
        val g = gatt ?: return
        try { g.disconnect() } catch (_: Throwable) {}
        try { g.close() } catch (_: Throwable) {}
        gatt = null
    }
}
