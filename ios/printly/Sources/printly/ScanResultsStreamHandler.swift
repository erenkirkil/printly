import CoreBluetooth
import Flutter

/// Owns the `printly/scan_results` event channel.
///
/// iOS only supports BLE scanning without MFi; the Classic wire code is
/// silently ignored in `types`. Discovery is unfiltered (services: nil)
/// because thermal printers do not share a well-known service UUID and a
/// filter would exclude valid peripherals.
final class ScanResultsStreamHandler: NSObject, FlutterStreamHandler {

    private let central: CentralController
    private var sink: FlutterEventSink?
    private var scanning = false

    /// Whether nameless advertisements are reported. Set per scan from the
    /// wire payload; false (the wire default) drops them in `didDiscover`
    /// before they cross the event channel — nameless results are
    /// overwhelmingly privacy-rotated phones/wearables/beacons, and a
    /// thermal printer must advertise its name to be pickable.
    private var includeUnnamed = false

    init(central: CentralController) {
        self.central = central
        super.init()
    }

    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        // Dart side lost interest — cancel any native scan so we aren't
        // consuming battery on advertisements no one is reading.
        stop()
        return nil
    }

    /// Starts a BLE scan once the central manager reports `.poweredOn`.
    ///
    /// Routed through `CentralController.onPoweredOn` instead of a
    /// synchronous state guard: the manager is `.unknown` right after lazy
    /// creation, so a synchronous check would deterministically fail the
    /// very first `startScan()` even with Bluetooth on. Terminal non-on
    /// states fail with the mapped reason (`.unauthorized` surfaces as
    /// `permission_denied`, matching Android).
    func start(
        types: [Int],
        includeUnnamed: Bool = false,
        completion: @escaping (Result<Void, PrintlyError>) -> Void
    ) {
        self.includeUnnamed = includeUnnamed
        guard types.contains(WireCodes.typeBle) else {
            // No BLE requested — nothing iOS can do (MFi Classic is out of
            // scope for Sprint 3).
            completion(.success(()))
            return
        }
        central.onPoweredOn { [weak self] outcome in
            guard let self = self else {
                // Handler torn down while queued — the engine is gone, so
                // nobody meaningfully observes this result.
                completion(.failure(.bluetoothUnavailable))
                return
            }
            switch outcome {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                if !self.scanning {
                    // A new scan invalidates the previous environment — drop
                    // cached peripherals nothing is connected to so the cache
                    // cannot grow without bound.
                    self.central.pruneDiscovered()
                    self.central.ensureManager().scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                    self.scanning = true
                }
                completion(.success(()))
            }
        }
    }

    func stop() {
        guard scanning else { return }
        central.ensureManager().stopScan()
        scanning = false
    }

    func detach() {
        stop()
        sink = nil
    }

    func didDiscover(
        peripheral: CBPeripheral,
        rssi: Int,
        advertisementData: [String: Any]
    ) {
        guard let sink = sink else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let resolvedName = peripheral.name ?? advertisedName
        // Mirrors the Android BleScanSession filter: nameless advertisements
        // never cross the channel unless the caller opted in. `peripheral.name`
        // survives frames that omit the local name (CoreBluetooth caches it),
        // so a real printer is not hidden when its ADV/scan-response split
        // carries the name only part of the time.
        if !includeUnnamed, resolvedName?.isEmpty != false { return }
        var map: [String: Any] = [
            WireCodes.Keys.address: peripheral.identifier.uuidString,
            WireCodes.Keys.type: WireCodes.typeBle,
            WireCodes.Keys.rssi: rssi,
            // iOS has no OS-level "bonded" concept comparable to Android's
            // BOND_BONDED; expose false so the Dart layer has a consistent
            // field to read.
            WireCodes.Keys.isBonded: false,
            // Unlike Android's Classic bonded-cache seed, CoreBluetooth never
            // synthesizes a discovery result from a stored pairing — every
            // callback here is a genuine advertisement, so this is always
            // true.
            WireCodes.Keys.seenInScan: true,
        ]
        if let name = resolvedName {
            map[WireCodes.Keys.name] = name
        }
        sink(map)
    }
}
