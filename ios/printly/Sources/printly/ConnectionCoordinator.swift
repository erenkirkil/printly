import CoreBluetooth

/// Owns the lifecycle of per-peripheral connection attempts and translates
/// Core Bluetooth delegate events into the shared connection-event wire
/// format. Post-link work (service discovery, chunked writes) lives in the
/// per-entry `PeripheralWriteSession`.
///
/// Classic and network transports are rejected on iOS — Classic requires
/// MFi certification (out of scope for generic thermal printers) and
/// network is TCP/9100, deferred to post-v1. Both paths emit a structured
/// error rather than hanging silently.
final class ConnectionCoordinator {

    /// Mirrors Android's `GATT_DISCONNECT_TIMEOUT_MS`: if CoreBluetooth never
    /// delivers `didDisconnect` after a cancel, force-reap the entry so the
    /// Dart side cannot wedge in `disconnecting`.
    private static let disconnectFallback: DispatchTimeInterval = .seconds(4)

    private let central: CentralController
    private let events: ConnectionEventsStreamHandler

    /// A class (not a struct) on purpose: the timeout and fallback reapers
    /// guard on the stored instance's identity (`===`) so a stale work item
    /// can never act on a fresh reconnect entry for the same UUID.
    private final class Entry {
        let payload: [String: Any]
        let peripheral: CBPeripheral
        var connectTimeout: DispatchWorkItem?
        var disconnectFallback: DispatchWorkItem?
        /// Post-link session: service discovery + chunked writes. Created in
        /// `didConnect`, torn down on every exit path so a pending write can
        /// never outlive its link.
        var session: PeripheralWriteSession?
        /// Ready-to-print (services discovered, write characteristic
        /// resolved) — the wire meaning of `connected`, matching Android.
        var ready = false

        init(payload: [String: Any], peripheral: CBPeripheral) {
            self.payload = payload
            self.peripheral = peripheral
        }

        func cancelTimers() {
            connectTimeout?.cancel()
            connectTimeout = nil
            disconnectFallback?.cancel()
            disconnectFallback = nil
        }

        func teardownSession() {
            session?.teardown(reason: WireCodes.Reasons.disconnected)
            session = nil
            ready = false
        }
    }

    private var entries: [UUID: Entry] = [:]

    /// UUIDs with a live connection entry — the peripherals the scan cache
    /// must keep retaining across a prune (CoreBluetooth drops connections
    /// whose CBPeripheral is deallocated).
    var liveUUIDs: Set<UUID> { Set(entries.keys) }

    init(central: CentralController, events: ConnectionEventsStreamHandler) {
        self.central = central
        self.events = events
    }

    func connect(payload: [String: Any], timeoutMs: Int?) {
        guard let type = payload[WireCodes.Keys.type] as? Int else {
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.invalidPayload)
            return
        }
        guard let address = payload[WireCodes.Keys.address] as? String else {
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.invalidPayload)
            return
        }

        switch type {
        case WireCodes.typeClassic:
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.classicRequiresMfi)
            return
        case WireCodes.typeNetwork:
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.networkNotSupported)
            return
        case WireCodes.typeBle:
            break
        default:
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.unsupportedTransport)
            return
        }

        guard let uuid = UUID(uuidString: address) else {
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.invalidAddress)
            return
        }

        if reemitIfDuplicate(uuid: uuid) { return }

        // Routed through the poweredOn queue: the manager is `.unknown`
        // right after lazy creation, so a synchronous state guard would
        // deterministically fail a cold-start connect (the documented
        // `reconnectLastDevice()` flow). Terminal non-on states map to the
        // shared reason vocabulary.
        central.onPoweredOn { [weak self] outcome in
            guard let self = self else { return }
            if case .failure(let error) = outcome {
                self.emit(payload: payload, state: WireCodes.stateError,
                          failureReason: error.reason)
                return
            }
            self.startBleConnect(payload: payload, uuid: uuid, timeoutMs: timeoutMs)
        }
    }

    /// When an entry already exists (typically a Flutter hot restart: the
    /// native process and its live link survive while the Dart side starts
    /// fresh), mirror Android and re-emit the current effective state so the
    /// restarted Dart side rehydrates instead of hanging into its connect
    /// timeout. Returns `true` when a duplicate was handled.
    private func reemitIfDuplicate(uuid: UUID) -> Bool {
        guard let existing = entries[uuid] else { return false }
        // `connected` on the wire means ready-to-print, so a link that is up
        // but still discovering services re-emits as `connecting`.
        let state = existing.ready
            ? WireCodes.stateConnected
            : WireCodes.stateConnecting
        emit(payload: existing.payload, state: state, failureReason: nil)
        return true
    }

    private func startBleConnect(payload: [String: Any], uuid: UUID, timeoutMs: Int?) {
        // Re-check after the (possibly async) poweredOn hop: two queued
        // connects for the same UUID must not open a second attempt.
        if reemitIfDuplicate(uuid: uuid) { return }

        guard let peripheral = central.peripheral(for: uuid) else {
            emit(payload: payload, state: WireCodes.stateError,
                 failureReason: WireCodes.Reasons.peripheralUnknown)
            return
        }

        let entry = Entry(payload: payload, peripheral: peripheral)
        entries[uuid] = entry
        emit(payload: payload, state: WireCodes.stateConnecting, failureReason: nil)

        // CBCentralManager.connect has no built-in timeout. Schedule a
        // cancellable work item so a stalled connect does not hang forever.
        // It runs through service discovery (Android parity: the connect
        // attempt only "succeeds" at ready-to-print), is cancelled on every
        // resolution path and guarded by entry identity, so it can never
        // kill a later attempt to the same UUID.
        if let timeoutMs = timeoutMs, timeoutMs > 0 {
            let work = DispatchWorkItem { [weak self, weak entry] in
                guard let self = self, let entry = entry,
                      self.entries[uuid] === entry,
                      !entry.ready else { return }
                entry.teardownSession()
                self.central.ensureManager().cancelPeripheralConnection(entry.peripheral)
                self.entries.removeValue(forKey: uuid)
                self.emit(
                    payload: entry.payload,
                    state: WireCodes.stateError,
                    failureReason: WireCodes.Reasons.connectTimeout
                )
            }
            entry.connectTimeout = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(timeoutMs),
                execute: work
            )
        }

        central.ensureManager().connect(peripheral, options: nil)
    }

    func disconnect(payload: [String: Any]) {
        guard let address = payload[WireCodes.Keys.address] as? String,
              let uuid = UUID(uuidString: address),
              let entry = entries[uuid] else {
            emit(payload: payload, state: WireCodes.stateDisconnected, failureReason: nil)
            return
        }

        emit(payload: entry.payload, state: WireCodes.stateDisconnecting, failureReason: nil)
        entry.cancelTimers()
        // Fail any in-flight write with `disconnected` before the link goes
        // down, and stop reporting ready so a racing write gets `not_ready`.
        entry.teardownSession()
        let manager = central.ensureManager()

        guard entry.peripheral.state == .connected else {
            // Cancelling a still-pending connect is not guaranteed to invoke
            // any delegate callback (a long-standing CoreBluetooth gap), so
            // reap the entry and emit the terminal state synchronously.
            entries.removeValue(forKey: uuid)
            manager.cancelPeripheralConnection(entry.peripheral)
            emit(payload: entry.payload, state: WireCodes.stateDisconnected, failureReason: nil)
            return
        }

        // Established link: didDisconnect normally emits the terminal state.
        // Mirror Android's 4 s fallback reaper in case the callback never
        // arrives; the identity guard (`===`) makes it a no-op if a fresh
        // reconnect entry has replaced this one in the meantime.
        let fallback = DispatchWorkItem { [weak self, weak entry] in
            guard let self = self, let entry = entry,
                  self.entries[uuid] === entry else { return }
            self.entries.removeValue(forKey: uuid)
            self.emit(payload: entry.payload, state: WireCodes.stateDisconnected, failureReason: nil)
        }
        entry.disconnectFallback = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.disconnectFallback,
            execute: fallback
        )
        manager.cancelPeripheralConnection(entry.peripheral)
    }

    func detach() {
        guard !entries.isEmpty else { return }
        let manager = central.ensureManager()
        for (_, entry) in entries {
            entry.cancelTimers()
            entry.teardownSession()
            manager.cancelPeripheralConnection(entry.peripheral)
        }
        entries.removeAll()
    }

    /// Routes a print payload to the device's write session. Mirrors
    /// Android's vocabulary: no live entry → `not_connected`, link up but
    /// discovery unresolved → `not_ready`; everything past that is the
    /// session's business (`write_busy`, `write_timeout`, ...). Completion
    /// receives `nil` on success or the wire reason string.
    func write(payload: [String: Any], bytes: Data, completion: @escaping (String?) -> Void) {
        guard let address = payload[WireCodes.Keys.address] as? String,
              let uuid = UUID(uuidString: address),
              let entry = entries[uuid] else {
            completion(WireCodes.Reasons.notConnected)
            return
        }
        guard entry.ready, let session = entry.session else {
            completion(WireCodes.Reasons.notReady)
            return
        }
        session.write(bytes, completion: completion)
    }

    // MARK: - Delegate routed calls

    func didConnect(peripheral: CBPeripheral) {
        guard let entry = entries[peripheral.identifier] else { return }
        // The link is up but not yet usable: `connected` is only emitted
        // once service discovery resolves a writable characteristic (wire
        // parity with Android, where `connected` means ready-to-print). The
        // connect timeout therefore keeps running through discovery.
        let uuid = peripheral.identifier
        let session = PeripheralWriteSession(peripheral: peripheral)
        entry.session = session
        session.prepare(
            onReady: { [weak self, weak entry] in
                guard let self = self, let entry = entry,
                      self.entries[uuid] === entry else { return }
                entry.ready = true
                entry.connectTimeout?.cancel()
                entry.connectTimeout = nil
                self.emit(payload: entry.payload,
                          state: WireCodes.stateConnected,
                          failureReason: nil)
            },
            onFailed: { [weak self, weak entry] reason in
                guard let self = self, let entry = entry,
                      self.entries[uuid] === entry else { return }
                entry.cancelTimers()
                entry.teardownSession()
                self.entries.removeValue(forKey: uuid)
                self.central.ensureManager().cancelPeripheralConnection(entry.peripheral)
                self.emit(payload: entry.payload,
                          state: WireCodes.stateError,
                          failureReason: reason)
            }
        )
    }

    func didFailToConnect(peripheral: CBPeripheral, error: Error?) {
        guard let entry = entries.removeValue(forKey: peripheral.identifier) else { return }
        entry.cancelTimers()
        entry.teardownSession()
        emit(
            payload: entry.payload,
            state: WireCodes.stateError,
            failureReason: error?.localizedDescription ?? WireCodes.Reasons.connectFailed
        )
    }

    func didDisconnect(peripheral: CBPeripheral, error: Error?) {
        guard let entry = entries.removeValue(forKey: peripheral.identifier) else { return }
        entry.cancelTimers()
        entry.teardownSession()
        if let error = error {
            emit(payload: entry.payload, state: WireCodes.stateError,
                 failureReason: error.localizedDescription)
        } else {
            emit(payload: entry.payload, state: WireCodes.stateDisconnected, failureReason: nil)
        }
    }

    private func emit(payload: [String: Any], state: Int, failureReason: String?) {
        var map: [String: Any] = [
            WireCodes.Keys.device: payload,
            WireCodes.Keys.state: state,
        ]
        if let reason = failureReason {
            map[WireCodes.Keys.failureReason] = reason
        }
        events.emit(map)
    }
}
