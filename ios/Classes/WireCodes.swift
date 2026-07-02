import CoreBluetooth

/// Stable integer protocol shared with the Dart side. Do not reorder —
/// the equivalent Dart enums (ConnectionType, ConnectionState,
/// BluetoothAdapterState) encode the same integer values.
enum WireCodes {
    // ConnectionType
    static let typeClassic = 0
    static let typeBle = 1
    static let typeNetwork = 2

    // ConnectionState
    static let stateDisconnected = 0
    static let stateConnecting = 1
    static let stateConnected = 2
    static let stateDisconnecting = 3
    static let stateReconnecting = 4
    static let stateError = 5

    // BluetoothAdapterState
    static let adapterUnknown = 0
    static let adapterResetting = 1
    static let adapterUnsupported = 2
    static let adapterUnauthorized = 3
    static let adapterPoweredOff = 4
    static let adapterPoweredOn = 5
}

extension WireCodes {
    static func adapterCode(for state: CBManagerState) -> Int {
        switch state {
        case .poweredOn: return adapterPoweredOn
        case .poweredOff: return adapterPoweredOff
        case .unauthorized: return adapterUnauthorized
        case .unsupported: return adapterUnsupported
        case .resetting: return adapterResetting
        case .unknown: return adapterUnknown
        @unknown default: return adapterUnknown
        }
    }
}

/// Stable string protocol shared with the Dart side (`WireProtocol` in
/// `wire_protocol.dart`) and Android (`WireCodes.kt`). Every channel name,
/// method name, payload key, and reason string must be referenced from here —
/// never inlined — and must stay byte-identical across the three languages.
extension WireCodes {

    /// Method/event channel names.
    enum Channels {
        static let method = "printly"
        static let adapterState = "printly/adapter_state"
        static let scanResults = "printly/scan_results"
        static let connectionEvents = "printly/connection_events"
    }

    /// Method-channel method names.
    enum Methods {
        static let getPlatformVersion = "getPlatformVersion"
        static let getAndroidSdkInt = "getAndroidSdkInt"
        static let openBluetoothSettings = "openBluetoothSettings"
        static let startScan = "startScan"
        static let stopScan = "stopScan"
        static let connect = "connect"
        static let disconnect = "disconnect"
        static let write = "write"
    }

    /// Payload keys used in method arguments and event maps.
    enum Keys {
        static let device = "device"
        static let timeoutMs = "timeoutMs"
        static let types = "types"
        static let bytes = "bytes"
        static let address = "address"
        static let type = "type"
        static let name = "name"
        static let rssi = "rssi"
        static let isBonded = "isBonded"
        static let state = "state"
        static let failureReason = "failureReason"
    }

    /// Machine-readable error strings — `PrintlyErrorCode.wireName` on the
    /// Dart side. Surfaced as `FlutterError` codes/messages and as
    /// connection-event `failureReason` values.
    enum Reasons {
        static let permissionDenied = "permission_denied"
        static let bluetoothUnavailable = "bluetooth_unavailable"
        static let bluetoothNotPoweredOn = "bluetooth_not_powered_on"
        static let startScanFailed = "start_scan_failed"
        static let connectTimeout = "connect_timeout"
        static let connectFailed = "connect_failed"
        static let disconnected = "disconnected"
        static let peripheralUnknown = "peripheral_unknown"
        static let notConnected = "not_connected"
        static let notReady = "not_ready"
        static let writeBusy = "write_busy"
        static let writeTimeout = "write_timeout"
        static let writeFailed = "write_failed"
        static let networkNotSupported = "network_not_supported"
        static let classicRequiresMfi = "classic_requires_mfi"
        static let unsupportedPlatform = "unsupported_platform"

        // Not part of the shared PrintlyErrorCode vocabulary, but still
        // channel-crossing strings that Android emits with identical bytes.
        static let invalidArgs = "invalid_args"
        static let invalidPayload = "invalid_payload"
        static let invalidAddress = "invalid_address"
        static let unsupportedTransport = "unsupported_transport"
    }
}

/// Structured native error carrying the shared wire vocabulary, replacing the
/// previous ad-hoc `NSError(domain: "printly", ...)`. Each case knows both the
/// `FlutterError` code and the machine-readable reason so the surfaced
/// `PlatformException` matches Android byte-for-byte.
enum PrintlyError: Error {
    /// CoreBluetooth authorization was denied (`CBManagerState.unauthorized`).
    case permissionDenied
    /// The device has no usable Bluetooth radio (`CBManagerState.unsupported`).
    case bluetoothUnavailable
    /// The radio exists but is switched off (`CBManagerState.poweredOff`).
    case bluetoothNotPoweredOn

    /// The wire string (`PrintlyErrorCode.wireName` on Dart).
    var reason: String {
        switch self {
        case .permissionDenied: return WireCodes.Reasons.permissionDenied
        case .bluetoothUnavailable: return WireCodes.Reasons.bluetoothUnavailable
        case .bluetoothNotPoweredOn: return WireCodes.Reasons.bluetoothNotPoweredOn
        }
    }

    /// The `FlutterError` code surfaced for method-channel failures.
    /// Permission problems keep their own code (Android parity: a
    /// `SecurityException` maps to `permission_denied` there); adapter
    /// problems fold under the operation-level `start_scan_failed` with the
    /// specific reason carried in the message.
    var flutterCode: String {
        switch self {
        case .permissionDenied:
            return WireCodes.Reasons.permissionDenied
        case .bluetoothUnavailable, .bluetoothNotPoweredOn:
            return WireCodes.Reasons.startScanFailed
        }
    }

    /// Maps a terminal `CBManagerState` to the matching error. Callers must
    /// not pass `.poweredOn` (not an error) or `.unknown`/`.resetting`
    /// (transient — queue instead, see `CentralController.onPoweredOn`).
    static func from(terminalState state: CBManagerState) -> PrintlyError {
        switch state {
        case .unauthorized: return .permissionDenied
        case .unsupported: return .bluetoothUnavailable
        default: return .bluetoothNotPoweredOn
        }
    }
}
