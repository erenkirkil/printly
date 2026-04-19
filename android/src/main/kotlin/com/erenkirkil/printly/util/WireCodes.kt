package com.erenkirkil.printly.util

/**
 * Stable integer protocol shared with the Dart side. Do not reorder — the
 * equivalent enums on the Dart side (ConnectionType, ConnectionState,
 * BluetoothAdapterState) encode the same integer values.
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
}
