package com.erenkirkil.printly

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import com.erenkirkil.printly.adapter.AdapterStateStreamHandler
import com.erenkirkil.printly.connection.ConnectionCoordinator
import com.erenkirkil.printly.connection.ConnectionEventsStreamHandler
import com.erenkirkil.printly.scan.ScanResultsStreamHandler
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

        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL_METHOD).also {
            it.setMethodCallHandler(this)
        }
        adapterStateChannel = EventChannel(binding.binaryMessenger, CHANNEL_ADAPTER_STATE).also {
            it.setStreamHandler(adapterStateHandler)
        }
        scanResultsChannel = EventChannel(binding.binaryMessenger, CHANNEL_SCAN_RESULTS).also {
            it.setStreamHandler(scanResultsHandler)
        }
        connectionEventsChannel = EventChannel(
            binding.binaryMessenger,
            CHANNEL_CONNECTION_EVENTS,
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
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "openBluetoothSettings" -> result.success(openBluetoothSettings())
            "startScan" -> handleStartScan(call, result)
            "stopScan" -> handleStopScan(result)
            "connect" -> handleConnect(call, result)
            "disconnect" -> handleDisconnect(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleStartScan(call: MethodCall, result: Result) {
        try {
            val types: List<Int> = call.argument<List<Any?>>("types")
                ?.mapNotNull { (it as? Number)?.toInt() }
                ?: emptyList()
            scanResultsHandler.start(types)
            result.success(null)
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message, null)
        } catch (e: Throwable) {
            result.error("start_scan_failed", e.message, null)
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
            val device: Map<String, Any?> = call.argument<Map<String, Any?>>("device")
                ?: return result.error("invalid_args", "device missing", null)
            val timeoutMs: Long? = (call.argument<Any?>("timeoutMs") as? Number)?.toLong()
            connectionCoordinator.connect(device, timeoutMs)
            result.success(null)
        } catch (e: Throwable) {
            result.error("connect_failed", e.message, null)
        }
    }

    private fun handleDisconnect(call: MethodCall, result: Result) {
        try {
            val device: Map<String, Any?> = call.argument<Map<String, Any?>>("device")
                ?: return result.error("invalid_args", "device missing", null)
            connectionCoordinator.disconnect(device)
            result.success(null)
        } catch (e: Throwable) {
            result.error("disconnect_failed", e.message, null)
        }
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

    private companion object {
        const val CHANNEL_METHOD = "printly"
        const val CHANNEL_ADAPTER_STATE = "printly/adapter_state"
        const val CHANNEL_SCAN_RESULTS = "printly/scan_results"
        const val CHANNEL_CONNECTION_EVENTS = "printly/connection_events"
    }
}
