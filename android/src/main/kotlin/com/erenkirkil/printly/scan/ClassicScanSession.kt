package com.erenkirkil.printly.scan

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import com.erenkirkil.printly.util.WireCodes

/**
 * Drives a Classic (BR/EDR) discovery cycle. `BluetoothAdapter.startDiscovery`
 * auto-stops after ~12 s on recent Android versions; the upper layer reissues
 * startScan if a longer window is requested.
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

    @SuppressLint("MissingPermission")
    fun start() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != BluetoothDevice.ACTION_FOUND) return
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
                if (device != null) onDevice(encode(device, rssi))
            }
        }
        receiver = r
        val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            appContext.registerReceiver(r, filter)
        }

        if (adapter.isDiscovering) {
            try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
        }
        try { adapter.startDiscovery() } catch (_: SecurityException) {}

        try {
            adapter.bondedDevices?.forEach { onDevice(encode(it, null)) }
        } catch (_: SecurityException) {
            // BLUETOOTH_CONNECT missing — skip bonded seed.
        }
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
    private fun encode(device: BluetoothDevice, rssi: Int?): Map<String, Any?> {
        val name: String? = try { device.name } catch (_: SecurityException) { null }
        val bonded: Boolean = try {
            device.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) { false }
        return buildMap {
            put("address", device.address)
            put("type", WireCodes.TYPE_CLASSIC)
            if (name != null) put("name", name)
            if (rssi != null) put("rssi", rssi)
            put("isBonded", bonded)
        }
    }
}
