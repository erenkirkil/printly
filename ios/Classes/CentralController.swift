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

    /// Operations parked while CoreBluetooth is still initialising. The
    /// manager reports `.unknown` synchronously after construction and only
    /// transitions via an async `centralManagerDidUpdateState`, so any
    /// first-use scan/connect must be deferred rather than guarded
    /// synchronously — a synchronous guard always fails on first use.
    private var pendingWhenPoweredOn: [(Result<Void, PrintlyError>) -> Void] = []

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

    /// Runs [block] once the central manager reaches a terminal state:
    /// immediately when already `.poweredOn`, queued while the transient
    /// `.unknown`/`.resetting` states last, or failed right away with the
    /// mapped reason on `.poweredOff`/`.unauthorized`/`.unsupported`.
    func onPoweredOn(_ block: @escaping (Result<Void, PrintlyError>) -> Void) {
        switch ensureManager().state {
        case .poweredOn:
            block(.success(()))
        case .unknown, .resetting:
            pendingWhenPoweredOn.append(block)
        case let terminal:
            block(.failure(PrintlyError.from(terminalState: terminal)))
        }
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

    /// Drops cached peripherals that no live connection entry references.
    /// Called when a new scan starts so the cache tracks the current
    /// environment instead of strongly retaining every peripheral ever seen.
    func pruneDiscovered() {
        let live = connection?.liveUUIDs ?? []
        discovered = discovered.filter { live.contains($0.key) }
    }

    /// Releases queued operations and cached peripherals when the engine
    /// detaches so nothing native outlives the Dart side.
    func detach() {
        pendingWhenPoweredOn.removeAll()
        discovered.removeAll()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        adapterState?.didUpdateState(central.state)
        flushPendingIfTerminal(central.state)
    }

    private func flushPendingIfTerminal(_ state: CBManagerState) {
        // .unknown/.resetting are transient — keep waiting for a terminal
        // state before resolving the queued operations.
        if state == .unknown || state == .resetting { return }
        guard !pendingWhenPoweredOn.isEmpty else { return }
        let blocks = pendingWhenPoweredOn
        pendingWhenPoweredOn.removeAll()
        let outcome: Result<Void, PrintlyError> = state == .poweredOn
            ? .success(())
            : .failure(PrintlyError.from(terminalState: state))
        for block in blocks {
            block(outcome)
        }
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
