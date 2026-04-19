import CoreBluetooth

/// Shared owner of `CBCentralManager`. Lazily instantiated on first use so
/// the iOS Bluetooth permission prompt does not appear at app launch (iOS
/// triggers the prompt whenever a CBCentralManager is constructed while
/// `NSBluetoothAlwaysUsageDescription` is declared).
///
/// All delegate events are routed to the three stream/connection handlers
/// via weak references so they can be released when the engine detaches,
/// without leaving the controller holding a dangling CBCentralManager.
final class CentralController: NSObject, CBCentralManagerDelegate {

    private var manager: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]

    weak var adapterState: AdapterStateStreamHandler?
    weak var scan: ScanResultsStreamHandler?
    weak var connection: ConnectionCoordinator?

    var state: CBManagerState {
        return manager?.state ?? .unknown
    }

    @discardableResult
    func ensureManager() -> CBCentralManager {
        if let m = manager { return m }
        // `queue: nil` → delegate callbacks arrive on the main thread,
        // which is exactly where we need to be to call into Flutter.
        let m = CBCentralManager(delegate: self, queue: nil, options: nil)
        manager = m
        return m
    }

    /// Resolves a peripheral by UUID. Prefers the in-memory scan cache and
    /// falls back to `retrievePeripherals(withIdentifiers:)` so a previously
    /// paired peripheral can be reconnected without re-scanning.
    func peripheral(for uuid: UUID) -> CBPeripheral? {
        if let cached = discovered[uuid] { return cached }
        let retrieved = manager?.retrievePeripherals(withIdentifiers: [uuid]).first
        if let p = retrieved { discovered[uuid] = p }
        return retrieved
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        adapterState?.didUpdateState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = peripheral
        scan?.didDiscover(
            peripheral: peripheral,
            rssi: RSSI.intValue,
            advertisementData: advertisementData
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connection?.didConnect(peripheral: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connection?.didFailToConnect(peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connection?.didDisconnect(peripheral: peripheral, error: error)
    }
}
