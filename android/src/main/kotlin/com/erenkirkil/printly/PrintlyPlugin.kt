package com.erenkirkil.printly

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Android implementation of the printly plugin.
 *
 * Exposes two channels to the Dart side:
 *  - `printly` (MethodChannel): one-shot calls such as `getPlatformVersion`
 *    and `openBluetoothSettings`.
 *  - `printly/adapter_state` (EventChannel): broadcast stream of
 *    [BluetoothAdapter] state changes, re-emitted using the shared wire
 *    protocol documented in `BluetoothAdapterState.fromCode`.
 */
class PrintlyPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var adapterStateChannel: EventChannel
    private lateinit var appContext: Context

    private var activity: Activity? = null
    private var adapterStateSink: EventChannel.EventSink? = null
    private var adapterStateReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        adapterStateChannel = EventChannel(binding.binaryMessenger, ADAPTER_STATE_CHANNEL)
        adapterStateChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        adapterStateChannel.setStreamHandler(null)
        detachAdapterStateReceiver()
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
            "getPlatformVersion" ->
                result.success("Android ${Build.VERSION.RELEASE}")
            "openBluetoothSettings" ->
                result.success(openBluetoothSettings())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        adapterStateSink = events ?: return
        events.success(encodeAdapterState(currentAdapter()))
        registerAdapterStateReceiver()
    }

    override fun onCancel(arguments: Any?) {
        detachAdapterStateReceiver()
        adapterStateSink = null
    }

    private fun openBluetoothSettings(): Boolean {
        val launcher = activity ?: appContext
        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
            if (launcher !is Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        return try {
            launcher.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun registerAdapterStateReceiver() {
        if (adapterStateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                val rawState = intent.getIntExtra(
                    BluetoothAdapter.EXTRA_STATE,
                    BluetoothAdapter.ERROR,
                )
                adapterStateSink?.success(
                    encodeAdapterStateFromRaw(rawState, currentAdapter()),
                )
            }
        }
        adapterStateReceiver = receiver
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            appContext.registerReceiver(receiver, filter)
        }
    }

    private fun detachAdapterStateReceiver() {
        val receiver = adapterStateReceiver ?: return
        try {
            appContext.unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered, ignore.
        }
        adapterStateReceiver = null
    }

    private fun currentAdapter(): BluetoothAdapter? {
        val manager = ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        ) ?: return null
        return manager.adapter
    }

    private fun encodeAdapterState(adapter: BluetoothAdapter?): Int {
        if (adapter == null) return CODE_UNSUPPORTED
        if (!hasBluetoothPermission()) return CODE_UNAUTHORIZED
        return if (adapter.isEnabled) CODE_POWERED_ON else CODE_POWERED_OFF
    }

    private fun encodeAdapterStateFromRaw(
        rawState: Int,
        adapter: BluetoothAdapter?,
    ): Int {
        if (adapter == null) return CODE_UNSUPPORTED
        if (!hasBluetoothPermission()) return CODE_UNAUTHORIZED
        return when (rawState) {
            BluetoothAdapter.STATE_ON -> CODE_POWERED_ON
            BluetoothAdapter.STATE_OFF -> CODE_POWERED_OFF
            BluetoothAdapter.STATE_TURNING_ON,
            BluetoothAdapter.STATE_TURNING_OFF -> CODE_RESETTING
            else -> CODE_UNKNOWN
        }
    }

    private fun hasBluetoothPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "printly"
        const val ADAPTER_STATE_CHANNEL = "printly/adapter_state"

        // Wire protocol codes, kept in sync with BluetoothAdapterState.fromCode on the Dart side.
        const val CODE_UNKNOWN = 0
        const val CODE_RESETTING = 1
        const val CODE_UNSUPPORTED = 2
        const val CODE_UNAUTHORIZED = 3
        const val CODE_POWERED_OFF = 4
        const val CODE_POWERED_ON = 5
    }
}
