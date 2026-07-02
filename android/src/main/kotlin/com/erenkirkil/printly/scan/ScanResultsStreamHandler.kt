package com.erenkirkil.printly.scan

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.util.PermissionChecker
import com.erenkirkil.printly.util.WireCodes
import io.flutter.plugin.common.EventChannel

/**
 * `printly/scan_results` event channel owner.
 *
 * The handler is long-lived; scan sessions are short-lived and driven by
 * explicit [start] / [stop] calls from the method channel. onListen simply
 * wires the sink — so when the Dart side subscribes before requesting a
 * scan, no events are missed once scanning actually starts.
 */
internal class ScanResultsStreamHandler(
    private val appContext: Context,
) : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var classic: ClassicScanSession? = null
    private var ble: BleScanSession? = null

    /**
     * Queried before starting Classic inquiry: while a connection is open,
     * running Classic discovery in parallel can stall or drop the link on many
     * controllers, so inquiry is skipped (bonded devices are still seeded).
     * Wired by the plugin to the connection coordinator.
     */
    var isConnectionActive: () -> Boolean = { false }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        // Dart side lost interest; cancel any underlying native scans so we
        // aren't consuming battery on advertisements no one is reading.
        stopAll()
    }

    /**
     * Begins scanning for the requested transport codes. Throws on missing
     * permission / unavailable hardware / powered-off adapter so the method
     * channel call can reject with a structured error.
     */
    fun start(types: List<Int>) {
        val adapter = currentAdapter()
            ?: throw IllegalStateException(WireCodes.Reasons.BLUETOOTH_UNAVAILABLE)
        if (!PermissionChecker.hasScan(appContext)) {
            throw SecurityException("bluetooth_scan_denied")
        }
        // With the adapter off the BLE scanner is null and Classic discovery
        // no-ops, so the scan would "succeed" and spin silently for the whole
        // timeout. Reject instead, matching the iOS powered-off behaviour.
        if (!adapter.isEnabled) {
            throw IllegalStateException(WireCodes.Reasons.BLUETOOTH_NOT_POWERED_ON)
        }

        stopAll()

        if (WireCodes.TYPE_CLASSIC in types) {
            val inquire = !isConnectionActive()
            classic = ClassicScanSession(appContext, adapter, ::emit)
                .also { it.start(inquire = inquire) }
        }
        if (WireCodes.TYPE_BLE in types) {
            ble = BleScanSession(adapter, ::emit, ::emitScanError).also { it.start() }
        }
    }

    fun stop() {
        stopAll()
    }

    fun detach() {
        stopAll()
        sink = null
    }

    private fun stopAll() {
        classic?.stop(); classic = null
        ble?.stop(); ble = null
    }

    private fun emit(map: Map<String, Any?>) {
        val s = sink ?: return
        mainHandler.post { s.success(map) }
    }

    private fun emitScanError(errorCode: Int) {
        // If Classic discovery is also running it still yields results, so a
        // BLE-only failure shouldn't kill the whole scan. Only surface when BLE
        // is the sole transport.
        if (classic != null) return
        val s = sink ?: return
        mainHandler.post {
            s.error("ble_scan_failed", "BLE scan failed (code $errorCode)", null)
        }
    }

    private fun currentAdapter(): BluetoothAdapter? =
        ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        )?.adapter
}
