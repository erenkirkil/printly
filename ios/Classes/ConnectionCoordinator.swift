import CoreBluetooth

/// Owns the lifecycle of per-peripheral connection attempts and translates
/// Core Bluetooth delegate events into the shared connection-event wire
/// format.
///
/// Classic and network transports are rejected on iOS — Classic requires
/// MFi certification (deferred to Sprint 6) and network is TCP/9100 which
/// will ship with the network sprint. Both paths emit a structured error
/// rather than hanging silently.
final class ConnectionCoordinator {

    private let central: CentralController
    private let events: ConnectionEventsStreamHandler

    private struct Entry {
        let payload: [String: Any]
        let peripheral: CBPeripheral
    }

    private var entries: [UUID: Entry] = [:]

    init(central: CentralController, events: ConnectionEventsStreamHandler) {
        self.central = central
        self.events = events
    }

    func connect(payload: [String: Any], timeoutMs: Int?) {
        guard let type = payload["type"] as? Int else {
            emit(payload: payload, state: WireCodes.stateError, failureReason: "invalid_payload")
            return
        }
        guard let address = payload["address"] as? String else {
            emit(payload: payload, state: WireCodes.stateError, failureReason: "invalid_payload")
            return
        }

        switch type {
        case WireCodes.typeClassic:
            emit(payload: payload, state: WireCodes.stateError, failureReason: "classic_requires_mfi")
            return
        case WireCodes.typeNetwork:
            emit(payload: payload, state: WireCodes.stateError, failureReason: "network_not_supported")
            return
        case WireCodes.typeBle:
            break
        default:
            emit(payload: payload, state: WireCodes.stateError, failureReason: "unsupported_transport")
            return
        }

        guard let uuid = UUID(uuidString: address) else {
            emit(payload: payload, state: WireCodes.stateError, failureReason: "invalid_address")
            return
        }

        let manager = central.ensureManager()
        guard manager.state == .poweredOn else {
            emit(payload: payload, state: WireCodes.stateError, failureReason: "bluetooth_not_powered_on")
            return
        }

        if entries[uuid] != nil {
            // Duplicate call — Dart layer de-dups, this is just defence in
            // depth. Do not open a second connect attempt.
            return
        }

        guard let peripheral = central.peripheral(for: uuid) else {
            emit(payload: payload, state: WireCodes.stateError, failureReason: "peripheral_unknown")
            return
        }

        entries[uuid] = Entry(payload: payload, peripheral: peripheral)
        emit(payload: payload, state: WireCodes.stateConnecting, failureReason: nil)

        // CBCentralManager.connect has no built-in timeout. Schedule a
        // cancelPeripheralConnection after the requested interval so a
        // stalled connect does not hang forever.
        if let timeoutMs = timeoutMs, timeoutMs > 0 {
            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self = self, let entry = self.entries[uuid] else { return }
                if entry.peripheral.state != .connected {
                    manager.cancelPeripheralConnection(entry.peripheral)
                    self.entries.removeValue(forKey: uuid)
                    self.emit(
                        payload: entry.payload,
                        state: WireCodes.stateError,
                        failureReason: "connect_timeout"
                    )
                }
            }
        }

        manager.connect(peripheral, options: nil)
    }

    func disconnect(payload: [String: Any]) {
        guard let address = payload["address"] as? String,
              let uuid = UUID(uuidString: address),
              let entry = entries[uuid] else {
            emit(payload: payload, state: WireCodes.stateDisconnected, failureReason: nil)
            return
        }
        emit(payload: entry.payload, state: WireCodes.stateDisconnecting, failureReason: nil)
        central.ensureManager().cancelPeripheralConnection(entry.peripheral)
        // The final `disconnected` state is emitted from the delegate
        // callback in didDisconnect below.
    }

    func detach() {
        let manager = central.ensureManager()
        for (_, entry) in entries {
            manager.cancelPeripheralConnection(entry.peripheral)
        }
        entries.removeAll()
    }

    // MARK: - Delegate routed calls

    func didConnect(peripheral: CBPeripheral) {
        guard let entry = entries[peripheral.identifier] else { return }
        emit(payload: entry.payload, state: WireCodes.stateConnected, failureReason: nil)
    }

    func didFailToConnect(peripheral: CBPeripheral, error: Error?) {
        guard let entry = entries.removeValue(forKey: peripheral.identifier) else { return }
        emit(
            payload: entry.payload,
            state: WireCodes.stateError,
            failureReason: error?.localizedDescription ?? "connect_failed"
        )
    }

    func didDisconnect(peripheral: CBPeripheral, error: Error?) {
        guard let entry = entries.removeValue(forKey: peripheral.identifier) else { return }
        if let error = error {
            emit(payload: entry.payload, state: WireCodes.stateError, failureReason: error.localizedDescription)
        } else {
            emit(payload: entry.payload, state: WireCodes.stateDisconnected, failureReason: nil)
        }
    }

    private func emit(payload: [String: Any], state: Int, failureReason: String?) {
        var map: [String: Any] = [
            "device": payload,
            "state": state,
        ]
        if let reason = failureReason {
            map["failureReason"] = reason
        }
        events.emit(map)
    }
}
