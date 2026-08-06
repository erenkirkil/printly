package com.erenkirkil.printly.util

/**
 * Stable wire protocol shared with the Dart side. Do not reorder or rename —
 * the Dart counterparts (`WireProtocol` in `wire_protocol.dart` for the
 * strings, ConnectionType/ConnectionState/BluetoothAdapterState for the
 * integers, `PrintlyErrorCode.wireName` for the reasons) encode the exact
 * same values, so every string must stay byte-identical.
 */
internal object WireCodes {
    // ConnectionType
    const val TYPE_CLASSIC = 0
    const val TYPE_BLE = 1
    const val TYPE_NETWORK = 2

    // ConnectionState
    const val STATE_DISCONNECTED = 0
    const val STATE_CONNECTING = 1
    const val STATE_CONNECTED = 2
    const val STATE_DISCONNECTING = 3
    const val STATE_RECONNECTING = 4
    const val STATE_ERROR = 5

    // BluetoothAdapterState
    const val ADAPTER_UNKNOWN = 0
    const val ADAPTER_RESETTING = 1
    const val ADAPTER_UNSUPPORTED = 2
    const val ADAPTER_UNAUTHORIZED = 3
    const val ADAPTER_POWERED_OFF = 4
    const val ADAPTER_POWERED_ON = 5

    /** Channel names — mirrors `WireProtocol` channel constants. */
    object Channels {
        const val METHOD = "printly"
        const val ADAPTER_STATE = "printly/adapter_state"
        const val SCAN_RESULTS = "printly/scan_results"
        const val CONNECTION_EVENTS = "printly/connection_events"
    }

    /** Method-channel method names — mirrors `WireProtocol.m*` constants. */
    object Methods {
        const val GET_PLATFORM_VERSION = "getPlatformVersion"
        const val GET_ANDROID_SDK_INT = "getAndroidSdkInt"
        const val OPEN_BLUETOOTH_SETTINGS = "openBluetoothSettings"
        const val REQUEST_ENABLE_BLUETOOTH = "requestEnableBluetooth"
        const val START_SCAN = "startScan"
        const val STOP_SCAN = "stopScan"
        const val CONNECT = "connect"
        const val DISCONNECT = "disconnect"
        const val WRITE = "write"
        const val IS_LOCATION_SERVICE_ENABLED = "isLocationServiceEnabled"
        const val OPEN_LOCATION_SETTINGS = "openLocationSettings"
    }

    /** Payload map keys — mirrors `WireProtocol.key*` constants. */
    object Keys {
        const val DEVICE = "device"
        const val TIMEOUT_MS = "timeoutMs"
        const val TYPES = "types"
        const val INCLUDE_UNNAMED = "includeUnnamed"
        const val BYTES = "bytes"
        const val ADDRESS = "address"
        const val TYPE = "type"
        const val NAME = "name"
        const val RSSI = "rssi"
        const val IS_BONDED = "isBonded"
        const val STATE = "state"
        const val FAILURE_REASON = "failureReason"
        const val SEEN_IN_SCAN = "seenInScan"
    }

    /**
     * Error codes / failure reasons — mirrors `PrintlyErrorCode.wireName`.
     * Emitted as PlatformException codes, exception messages, and
     * connection-event failure reasons.
     */
    object Reasons {
        const val PERMISSION_DENIED = "permission_denied"
        const val BLUETOOTH_UNAVAILABLE = "bluetooth_unavailable"
        const val BLUETOOTH_NOT_POWERED_ON = "bluetooth_not_powered_on"
        const val START_SCAN_FAILED = "start_scan_failed"
        const val CONNECT_TIMEOUT = "connect_timeout"
        const val CONNECT_FAILED = "connect_failed"
        const val DISCONNECTED = "disconnected"
        const val NOT_CONNECTED = "not_connected"
        const val NOT_READY = "not_ready"
        const val WRITE_BUSY = "write_busy"
        const val WRITE_TIMEOUT = "write_timeout"
        const val WRITE_FAILED = "write_failed"
        const val NETWORK_NOT_SUPPORTED = "network_not_supported"
        const val UNSUPPORTED_PLATFORM = "unsupported_platform"
        const val LOCATION_SERVICES_DISABLED = "location_services_disabled"
    }
}
