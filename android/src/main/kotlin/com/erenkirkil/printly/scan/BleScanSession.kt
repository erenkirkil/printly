package com.erenkirkil.printly.scan

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import com.erenkirkil.printly.util.WireCodes

/**
 * BLE discovery via the modern `BluetoothLeScanner` API. The legacy
 * `BluetoothAdapter.startLeScan` is deprecated on API 21+ and not used.
 *
 * Scan mode is LOW_LATENCY because printer discovery is typically a
 * foreground, user-initiated action on a short window; power impact is
 * bounded by the upper-layer scan timeout.
 */
internal class BleScanSession(
    adapter: BluetoothAdapter,
    private val onDevice: (Map<String, Any?>) -> Unit,
    private val onError: (Int) -> Unit = {},
    private val includeUnnamed: Boolean = false,
) {
    private val scanner: BluetoothLeScanner? = adapter.bluetoothLeScanner
    private var callback: ScanCallback? = null

    @SuppressLint("MissingPermission")
    fun start() {
        if (callback != null) return
        val s = scanner ?: return

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = emit(result)
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::emit)
            }
            override fun onScanFailed(errorCode: Int) {
                // Surface the failure so the upper layer can stop the spinner
                // and report it, instead of the user waiting out the timeout.
                // (Android throttles opportunistic scans after 5 starts / 30 s.)
                onError(errorCode)
            }
        }
        callback = cb
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            s.startScan(emptyList(), settings, cb)
        } catch (_: SecurityException) {
            callback = null
        }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        val cb = callback ?: return
        try { scanner?.stopScan(cb) } catch (_: SecurityException) {}
        callback = null
    }

    @SuppressLint("MissingPermission")
    private fun emit(result: ScanResult) {
        val device: BluetoothDevice = result.device
        val name: String? = try {
            result.scanRecord?.deviceName ?: device.name
        } catch (_: SecurityException) { null }
        // Nameless advertisements are overwhelmingly privacy-rotated phones,
        // wearables and beacons (135 of 141 records in one office scan) — a
        // thermal printer must advertise its name to be pickable. Dropping
        // them HERE keeps them off the binder->channel->Dart path entirely.
        // Note the `device.name` fallback above: a named printer whose ADV
        // frame omits the local name still resolves through the adapter
        // cache, so real printers are not hidden by this filter. Android's
        // ScanFilter cannot express "has any name" (setDeviceName is an
        // exact match), hence the manual check.
        if (!includeUnnamed && name.isNullOrBlank()) return
        val bonded: Boolean = try {
            device.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) { false }
        onDevice(buildMap {
            put(WireCodes.Keys.ADDRESS, device.address)
            put(WireCodes.Keys.TYPE, WireCodes.TYPE_BLE)
            if (name != null) put(WireCodes.Keys.NAME, name)
            put(WireCodes.Keys.RSSI, result.rssi)
            put(WireCodes.Keys.IS_BONDED, bonded)
            put(WireCodes.Keys.SEEN_IN_SCAN, true)
        })
    }
}
