package com.erenkirkil.printly.connection

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Pure event sink for `printly/connection_events`. The coordinator calls
 * [emit] from background (binder) threads; we hop to the main thread before
 * handing the map to Flutter, which is the only thread where EventSink
 * methods are safe to invoke.
 */
internal class ConnectionEventsStreamHandler : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        val s = sink ?: return
        mainHandler.post { s.success(event) }
    }

    fun detach() {
        sink = null
    }
}
