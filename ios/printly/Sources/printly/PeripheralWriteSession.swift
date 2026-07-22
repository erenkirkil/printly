import CoreBluetooth

/// Per-peripheral GATT session covering everything after the link comes up:
/// service discovery, write-characteristic resolution, and chunked writes.
/// The iOS counterpart of Android's `GattConnectionSession`.
///
/// `onReady` fires only once the link is actually usable for printing —
/// services discovered **and** a writable characteristic resolved — matching
/// the wire-state contract where `connected` means ready-to-print. Any
/// discovery failure reports `onFailed` with the shared reason vocabulary.
///
/// Writes are split into single-ATT-packet chunks and sent one at a time,
/// each bounded by a watchdog so a stalled printer cannot hang a print job
/// forever. All state is main-thread confined: the owning
/// `CBCentralManager` is created with `queue: nil`, so every peripheral
/// delegate callback already arrives on main.
final class PeripheralWriteSession: NSObject, CBPeripheralDelegate {

    /// Common thermal BLE-SPP write characteristics, tried in order before
    /// falling back to the first writable characteristic found.
    /// Byte-identical with Android's `PREFERRED_WRITE_UUIDS`.
    private static let preferredWriteUuids: [CBUUID] = [
        CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"),
        CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB"),
    ]

    /// Per-chunk deadline (Android parity: `WRITE_TIMEOUT_MS`). Covers both
    /// a missing write acknowledgement and a `peripheralIsReady` callback
    /// that never arrives.
    private static let writeTimeout: DispatchTimeInterval = .seconds(5)

    private let peripheral: CBPeripheral

    private var onReady: (() -> Void)?
    private var onFailed: ((String) -> Void)?

    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var pendingServices = 0
    /// Discovery resolved (ready or failed) — late CoreBluetooth callbacks
    /// must not re-enter the resolution path.
    private var settled = false
    private var tornDown = false

    private var pendingChunks: [Data] = []
    private var pendingCompletion: ((String?) -> Void)?
    /// Parked on a full local send buffer, resumed by
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`.
    private var awaitingCanSend = false
    private var watchdog: DispatchWorkItem?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
    }

    /// Starts service discovery. Exactly one of [onReady]/[onFailed] fires
    /// unless the session is torn down first.
    func prepare(onReady: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        guard !tornDown, !settled else { return }
        self.onReady = onReady
        self.onFailed = onFailed
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    /// Fails any in-flight write with [reason], cancels timers, and detaches
    /// from the peripheral. Idempotent — safe to call from the coordinator's
    /// disconnect, timeout, and delegate paths alike.
    func teardown(reason: String) {
        if tornDown { return }
        tornDown = true
        settled = true
        cancelWatchdog()
        awaitingCanSend = false
        onReady = nil
        onFailed = nil
        finishWrite(reason)
        if peripheral.delegate === self {
            peripheral.delegate = nil
        }
    }

    // MARK: - Discovery

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !settled else { return }
        if error != nil {
            fail(WireCodes.Reasons.serviceDiscoveryFailed)
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            fail(WireCodes.Reasons.noWritableCharacteristic)
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !settled else { return }
        // A characteristic-level error on one service is not fatal — another
        // service may still carry the write characteristic, so resolution
        // waits for the full sweep and judges what it finds.
        pendingServices -= 1
        if pendingServices <= 0 {
            resolveWriteCharacteristic()
        }
    }

    private func resolveWriteCharacteristic() {
        let writable = (peripheral.services ?? [])
            .flatMap { $0.characteristics ?? [] }
            .filter {
                $0.properties.contains(.write)
                    || $0.properties.contains(.writeWithoutResponse)
            }
        let chosen = Self.preferredWriteUuids
            .compactMap { uuid in writable.first { $0.uuid == uuid } }
            .first
            ?? writable.first
        guard let characteristic = chosen else {
            fail(WireCodes.Reasons.noWritableCharacteristic)
            return
        }
        // The opposite preference from Android, deliberately: Android favours
        // no-response writes because its stack still delivers a per-chunk
        // "ready for the next write" callback. iOS delivers nothing for
        // `.withoutResponse` — `canSendWriteWithoutResponse` only reflects
        // the local buffer, not the printer — so acknowledged writes are the
        // only end-to-end backpressure available. Cheap BLE-UART bridges
        // overflow without it. Revisit for raster throughput if hardware
        // testing shows the round trips dominate.
        writeType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        writeChar = characteristic
        settled = true
        let callback = onReady
        onReady = nil
        onFailed = nil
        callback?()
    }

    private func fail(_ reason: String) {
        settled = true
        let callback = onFailed
        onReady = nil
        onFailed = nil
        callback?(reason)
    }

    // MARK: - Write

    /// Splits [bytes] into chunks and writes them sequentially, bounded by a
    /// per-chunk watchdog. Rejects with `not_ready` before a writable
    /// characteristic is resolved and `write_busy` while a previous write is
    /// still draining — the same vocabulary as Android.
    func write(_ bytes: Data, completion: @escaping (String?) -> Void) {
        guard !tornDown, writeChar != nil else {
            completion(WireCodes.Reasons.notReady)
            return
        }
        guard pendingCompletion == nil else {
            completion(WireCodes.Reasons.writeBusy)
            return
        }
        if bytes.isEmpty {
            completion(nil)
            return
        }
        // Chunk to the no-response maximum (= ATT MTU − 3) even for
        // acknowledged writes: the with-response maximum reports 512 because
        // iOS would transparently switch to ATT prepared/long writes, which
        // cheap printer firmware routinely mishandles. One chunk = one plain
        // ATT packet, exactly like Android's `mtu - ATT_HEADER_BYTES`.
        let chunkSize = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var chunks: [Data] = []
        chunks.reserveCapacity((bytes.count + chunkSize - 1) / chunkSize)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            chunks.append(bytes.subdata(in: offset..<end))
            offset = end
        }
        pendingChunks = chunks
        pendingCompletion = completion
        writeNextChunk()
    }

    private func writeNextChunk() {
        guard pendingCompletion != nil else { return }
        guard let characteristic = writeChar, !tornDown else {
            finishWrite(WireCodes.Reasons.notConnected)
            return
        }
        // No-response chunks drain in a loop while the local buffer accepts
        // them; acknowledged chunks go one at a time, gated on the write
        // response. Both paths park under a watchdog whenever they wait on
        // a callback.
        while let chunk = pendingChunks.first {
            if writeType == .withoutResponse {
                if !peripheral.canSendWriteWithoutResponse {
                    awaitingCanSend = true
                    scheduleWatchdog()
                    return
                }
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
                pendingChunks.removeFirst()
            } else {
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                scheduleWatchdog()
                return
            }
        }
        finishWrite(nil)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard pendingCompletion != nil, writeType == .withResponse else { return }
        cancelWatchdog()
        if let error = error {
            finishWrite(error.localizedDescription)
            return
        }
        if !pendingChunks.isEmpty {
            pendingChunks.removeFirst()
        }
        writeNextChunk()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard awaitingCanSend else { return }
        awaitingCanSend = false
        cancelWatchdog()
        writeNextChunk()
    }

    // MARK: - Watchdog

    private func scheduleWatchdog() {
        cancelWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.awaitingCanSend = false
            self.finishWrite(WireCodes.Reasons.writeTimeout)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeTimeout, execute: work)
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func finishWrite(_ reason: String?) {
        cancelWatchdog()
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        pendingChunks = []
        completion(reason)
    }
}
