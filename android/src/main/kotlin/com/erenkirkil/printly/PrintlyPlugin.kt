package com.erenkirkil.printly

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.adapter.AdapterStateStreamHandler
import com.erenkirkil.printly.connection.ConnectionCoordinator
import com.erenkirkil.printly.connection.ConnectionEventsStreamHandler
import com.erenkirkil.printly.scan.ScanResultsStreamHandler
import com.erenkirkil.printly.util.LocationServices
import com.erenkirkil.printly.util.PermissionChecker
import com.erenkirkil.printly.util.WireCodes
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Android entry point for the printly plugin.
 *
 * The plugin itself is intentionally thin: it wires Flutter channels to
 * dedicated handlers and coordinators in the sibling packages — keeping
 * each concern (adapter state, scan, connection) in its own file with a
 * single responsibility instead of one monolithic god class.
 */
class PrintlyPlugin : FlutterPlugin, ActivityAware, MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var adapterStateChannel: EventChannel
    private lateinit var scanResultsChannel: EventChannel
    private lateinit var connectionEventsChannel: EventChannel
    private lateinit var appContext: Context

    private lateinit var adapterStateHandler: AdapterStateStreamHandler
    private lateinit var scanResultsHandler: ScanResultsStreamHandler
    private lateinit var connectionEventsHandler: ConnectionEventsStreamHandler
    private lateinit var connectionCoordinator: ConnectionCoordinator

    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        adapterStateHandler = AdapterStateStreamHandler(appContext)
        scanResultsHandler = ScanResultsStreamHandler(appContext)
        connectionEventsHandler = ConnectionEventsStreamHandler()
        connectionCoordinator = ConnectionCoordinator(appContext, connectionEventsHandler)
        // Skip Classic inquiry while a link is open — inquiry can stall/drop it.
        scanResultsHandler.isConnectionActive = connectionCoordinator::hasActiveConnections

        methodChannel = MethodChannel(binding.binaryMessenger, WireCodes.Channels.METHOD).also {
            it.setMethodCallHandler(this)
        }
        adapterStateChannel = EventChannel(
            binding.binaryMessenger,
            WireCodes.Channels.ADAPTER_STATE,
        ).also { it.setStreamHandler(adapterStateHandler) }
        scanResultsChannel = EventChannel(
            binding.binaryMessenger,
            WireCodes.Channels.SCAN_RESULTS,
        ).also { it.setStreamHandler(scanResultsHandler) }
        connectionEventsChannel = EventChannel(
            binding.binaryMessenger,
            WireCodes.Channels.CONNECTION_EVENTS,
        ).also { it.setStreamHandler(connectionEventsHandler) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        adapterStateChannel.setStreamHandler(null)
        scanResultsChannel.setStreamHandler(null)
        connectionEventsChannel.setStreamHandler(null)

        adapterStateHandler.detach()
        scanResultsHandler.detach()
        connectionEventsHandler.detach()
        connectionCoordinator.detach()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            WireCodes.Methods.GET_PLATFORM_VERSION ->
                result.success("Android ${Build.VERSION.RELEASE}")
            WireCodes.Methods.GET_ANDROID_SDK_INT -> result.success(Build.VERSION.SDK_INT)
            WireCodes.Methods.OPEN_BLUETOOTH_SETTINGS -> result.success(openBluetoothSettings())
            WireCodes.Methods.REQUEST_ENABLE_BLUETOOTH -> handleRequestEnableBluetooth(result)
            WireCodes.Methods.START_SCAN -> handleStartScan(call, result)
            WireCodes.Methods.STOP_SCAN -> handleStopScan(result)
            WireCodes.Methods.CONNECT -> handleConnect(call, result)
            WireCodes.Methods.DISCONNECT -> handleDisconnect(call, result)
            WireCodes.Methods.WRITE -> handleWrite(call, result)
            WireCodes.Methods.IS_LOCATION_SERVICE_ENABLED ->
                result.success(LocationServices.isSatisfied(appContext))
            WireCodes.Methods.OPEN_LOCATION_SETTINGS ->
                result.success(openLocationSettings())
            else -> result.notImplemented()
        }
    }

    private fun handleStartScan(call: MethodCall, result: Result) {
        try {
            val types: List<Int> = call.argument<List<Any?>>(WireCodes.Keys.TYPES)
                ?.mapNotNull { (it as? Number)?.toInt() }
                ?: emptyList()
            val includeUnnamed: Boolean =
                call.argument<Boolean>(WireCodes.Keys.INCLUDE_UNNAMED) ?: false
            scanResultsHandler.start(types, includeUnnamed)
            result.success(null)
        } catch (e: SecurityException) {
            result.error(WireCodes.Reasons.PERMISSION_DENIED, e.message, null)
        } catch (e: Throwable) {
            result.error(WireCodes.Reasons.START_SCAN_FAILED, e.message, null)
        }
    }

    private fun handleStopScan(result: Result) {
        try {
            scanResultsHandler.stop()
            result.success(null)
        } catch (e: Throwable) {
            result.error("stop_scan_failed", e.message, null)
        }
    }

    private fun handleConnect(call: MethodCall, result: Result) {
        try {
            val device: Map<String, Any?> =
                call.argument<Map<String, Any?>>(WireCodes.Keys.DEVICE)
                    ?: return result.error("invalid_args", "device missing", null)
            val timeoutMs: Long? =
                (call.argument<Any?>(WireCodes.Keys.TIMEOUT_MS) as? Number)?.toLong()
            connectionCoordinator.connect(device, timeoutMs)
            result.success(null)
        } catch (e: Throwable) {
            result.error(WireCodes.Reasons.CONNECT_FAILED, e.message, null)
        }
    }

    private fun handleDisconnect(call: MethodCall, result: Result) {
        try {
            val device: Map<String, Any?> =
                call.argument<Map<String, Any?>>(WireCodes.Keys.DEVICE)
                    ?: return result.error("invalid_args", "device missing", null)
            connectionCoordinator.disconnect(device)
            result.success(null)
        } catch (e: Throwable) {
            result.error("disconnect_failed", e.message, null)
        }
    }

    private fun handleWrite(call: MethodCall, result: Result) {
        val device: Map<String, Any?> =
            call.argument<Map<String, Any?>>(WireCodes.Keys.DEVICE)
                ?: return result.error("invalid_args", "device missing", null)
        val bytes: ByteArray = call.argument<ByteArray>(WireCodes.Keys.BYTES)
            ?: return result.error("invalid_args", "bytes missing", null)
        connectionCoordinator.write(device, bytes) { error ->
            if (error == null) {
                result.success(null)
            } else {
                // Pass shared-vocabulary reasons through as their own codes so
                // Dart can classify them; anything else collapses to the
                // generic write_failed with the raw reason in the message.
                val code = when (error.message) {
                    WireCodes.Reasons.NOT_CONNECTED,
                    WireCodes.Reasons.NOT_READY,
                    WireCodes.Reasons.WRITE_BUSY,
                    WireCodes.Reasons.WRITE_TIMEOUT,
                    WireCodes.Reasons.DISCONNECTED,
                    -> error.message!!
                    else -> WireCodes.Reasons.WRITE_FAILED
                }
                result.error(code, error.message, null)
            }
        }
    }

    /**
     * Shows the system "turn Bluetooth on" dialog (`ACTION_REQUEST_ENABLE`)
     * over the current activity — the app is never backgrounded. Returns
     * `false` as a no-op when the adapter is unavailable or already
     * enabled; the caller must watch the adapter-state stream for the
     * user's actual decision, since this only reports whether the dialog
     * was shown.
     */
    private fun handleRequestEnableBluetooth(result: Result) {
        val adapter = ContextCompat.getSystemService(
            appContext,
            android.bluetooth.BluetoothManager::class.java,
        )?.adapter
        if (adapter == null) {
            result.success(false)
            return
        }
        val enabled = try { adapter.isEnabled } catch (_: SecurityException) { false }
        if (enabled) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT >= 31 &&
            !PermissionChecker.hasConnect(appContext)
        ) {
            // The system dialog itself requires BLUETOOTH_CONNECT on 12+;
            // failing fast with the shared wire reason lets Dart surface the
            // typed permission exception instead of a mystery no-op.
            result.error(WireCodes.Reasons.PERMISSION_DENIED, "bluetooth_connect_required", null)
            return
        }
        val launcher: Context = activity ?: appContext
        val intent = Intent(android.bluetooth.BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
            if (launcher !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        result.success(
            try {
                launcher.startActivity(intent)
                true
            } catch (_: SecurityException) {
                false
            } catch (_: Exception) {
                false
            },
        )
    }

    private fun openBluetoothSettings(): Boolean {
        val launcher: Context = activity ?: appContext
        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
            if (launcher !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            launcher.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openLocationSettings(): Boolean {
        val launcher: Context = activity ?: appContext
        val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
            if (launcher !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            launcher.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
