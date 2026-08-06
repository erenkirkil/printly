package com.erenkirkil.printly.scan

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.util.WireCodes

/**
 * Drives a Classic (BR/EDR) discovery cycle. `BluetoothAdapter.startDiscovery`
 * auto-stops after ~12 s, so the session re-arms itself on
 * `ACTION_DISCOVERY_FINISHED` until [stop] is called — otherwise a printer
 * powered on (or brought into range) a few seconds late would never appear even
 * though the UI still says it is scanning.
 *
 * Bonded devices are emitted eagerly on start so users see already-paired
 * printers immediately, without waiting for a fresh inquiry response.
 */
internal class ClassicScanSession(
    private val appContext: Context,
    private val adapter: BluetoothAdapter,
    private val onDevice: (Map<String, Any?>) -> Unit,
) {
    private var receiver: BroadcastReceiver? = null

    /**
     * Starts discovery. When [inquire] is false only the bonded devices are
     * seeded and no inquiry is run — used while a connection is open, because
     * Classic inquiry monopolises the radio and can stall/drop an active link.
     */
    @SuppressLint("MissingPermission")
    fun start(inquire: Boolean = true) {
        if (receiver != null) return

        try {
            adapter.bondedDevices?.forEach { onDevice(encode(it, null, seenInScan = false)) }
        } catch (_: SecurityException) {
            // BLUETOOTH_CONNECT missing — skip bonded seed.
        }
        if (!inquire) return

        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> onFound(intent)
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> reArm()
                }
            }
        }
        receiver = r
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        ContextCompat.registerReceiver(
            appContext,
            r,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        if (adapter.isDiscovering) {
            try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
        }
        try { adapter.startDiscovery() } catch (_: SecurityException) {}
    }

    @SuppressLint("MissingPermission")
    private fun onFound(intent: Intent) {
        val device: BluetoothDevice? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(
                    BluetoothDevice.EXTRA_DEVICE,
                    BluetoothDevice::class.java,
                )
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
        val rssi: Int? = intent.getShortExtra(
            BluetoothDevice.EXTRA_RSSI,
            Short.MIN_VALUE,
        ).takeIf { it != Short.MIN_VALUE }?.toInt()
        if (device != null) onDevice(encode(device, rssi, seenInScan = true))
    }

    @SuppressLint("MissingPermission")
    private fun reArm() {
        // Discovery ended on its own; restart it unless we've been stopped so
        // late-appearing devices keep surfacing for the whole scan window.
        if (receiver == null) return
        try { adapter.startDiscovery() } catch (_: SecurityException) {}
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        receiver?.let {
            try {
                appContext.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {}
        }
        receiver = null
        try {
            if (adapter.isDiscovering) adapter.cancelDiscovery()
        } catch (_: SecurityException) {}
    }

    @SuppressLint("MissingPermission")
    private fun encode(
        device: BluetoothDevice,
        rssi: Int?,
        seenInScan: Boolean,
    ): Map<String, Any?> {
        val name: String? = try { device.name } catch (_: SecurityException) { null }
        val bonded: Boolean = try {
            device.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) { false }
        return buildMap {
            put(WireCodes.Keys.ADDRESS, device.address)
            put(WireCodes.Keys.TYPE, WireCodes.TYPE_CLASSIC)
            if (name != null) put(WireCodes.Keys.NAME, name)
            if (rssi != null) put(WireCodes.Keys.RSSI, rssi)
            put(WireCodes.Keys.IS_BONDED, bonded)
            put(WireCodes.Keys.SEEN_IN_SCAN, seenInScan)
        }
    }
}
