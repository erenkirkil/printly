package com.erenkirkil.printly.adapter

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import com.erenkirkil.printly.util.WireCodes
import io.flutter.plugin.common.EventChannel

/**
 * Owns the `printly/adapter_state` event channel. Seeds the stream with the
 * current adapter state on subscribe and then mirrors the system broadcast
 * receiver until the Dart listener cancels.
 */
internal class AdapterStateStreamHandler(
    private val appContext: Context,
) : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val safe = events ?: return
        sink = safe
        safe.success(encode(currentAdapter()))
        register()
    }

    override fun onCancel(arguments: Any?) {
        unregister()
        sink = null
    }

    /** Called from the plugin's onDetachedFromEngine to release OS resources. */
    fun detach() {
        unregister()
        sink = null
    }

    private fun register() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                val raw = intent.getIntExtra(
                    BluetoothAdapter.EXTRA_STATE,
                    BluetoothAdapter.ERROR,
                )
                sink?.success(encodeFromRaw(raw, currentAdapter()))
            }
        }
        receiver = r
        ContextCompat.registerReceiver(
            appContext,
            r,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun unregister() {
        val r = receiver ?: return
        try {
            appContext.unregisterReceiver(r)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        }
        receiver = null
    }

    private fun currentAdapter(): BluetoothAdapter? =
        ContextCompat.getSystemService(
            appContext,
            BluetoothManager::class.java,
        )?.adapter

    private fun encode(adapter: BluetoothAdapter?): Int {
        if (adapter == null) return WireCodes.ADAPTER_UNSUPPORTED
        // The permission short-circuit that used to live here synthesized
        // ADAPTER_UNAUTHORIZED, conflating "radio state" with "permission
        // state" — and because Android only broadcasts ACTION_STATE_CHANGED
        // for radio transitions, the value froze until process restart once
        // emitted. Permission is now the consumer's question to ask via
        // checkPermissions(); this channel reports the radio alone.
        // BluetoothAdapter.isEnabled is annotated BLUETOOTH_CONNECT on
        // API 31+, so without the permission some OEM builds throw — fall
        // back to UNKNOWN rather than lying about the radio.
        return try {
            if (adapter.isEnabled) {
                WireCodes.ADAPTER_POWERED_ON
            } else {
                WireCodes.ADAPTER_POWERED_OFF
            }
        } catch (_: SecurityException) {
            WireCodes.ADAPTER_UNKNOWN
        }
    }

    private fun encodeFromRaw(raw: Int, adapter: BluetoothAdapter?): Int {
        if (adapter == null) return WireCodes.ADAPTER_UNSUPPORTED
        return when (raw) {
            BluetoothAdapter.STATE_ON -> WireCodes.ADAPTER_POWERED_ON
            BluetoothAdapter.STATE_OFF -> WireCodes.ADAPTER_POWERED_OFF
            BluetoothAdapter.STATE_TURNING_ON,
            BluetoothAdapter.STATE_TURNING_OFF -> WireCodes.ADAPTER_RESETTING
            else -> WireCodes.ADAPTER_UNKNOWN
        }
    }
}
