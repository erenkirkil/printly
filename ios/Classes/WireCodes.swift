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
