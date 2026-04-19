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
     * permission / unavailable hardware so the method channel call can
     * reject with a structured error.
     */
    fun start(types: List<Int>) {
        val adapter = currentAdapter() ?: throw IllegalStateException("bluetooth_unavailable")
        if (!PermissionChecker.hasScan(appContext)) {
            throw SecurityException("bluetooth_scan_denied")
        }

        stopAll()

        if (WireCodes.TYPE_CLASSIC in types) {
            classic = ClassicScanSession(appContext, adapter, ::emit).also { it.start() }
        }
        if (WireCodes.TYPE_BLE in types) {
            ble = BleScanSession(adapter, ::emit).also { it.start() }
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

    private fun currentAdapter(): BluetoothAdapter? =
        ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        )?.adapter
}
