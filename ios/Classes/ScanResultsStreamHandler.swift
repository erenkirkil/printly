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

    func start(types: [Int]) throws {
        guard types.contains(WireCodes.typeBle) else {
            // No BLE requested — nothing iOS can do (MFi Classic is out of
            // scope for Sprint 3).
            return
        }
        let manager = central.ensureManager()
        guard manager.state == .poweredOn else {
            throw NSError(
                domain: "printly",
                code: WireCodes.stateError,
                userInfo: [NSLocalizedDescriptionKey: "bluetooth_not_powered_on"]
            )
        }
        if scanning { return }
        manager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanning = true
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
        var map: [String: Any] = [
            "address": peripheral.identifier.uuidString,
            "type": WireCodes.typeBle,
            "rssi": rssi,
            // iOS has no OS-level "bonded" concept comparable to Android's
            // BOND_BONDED; expose false so the Dart layer has a consistent
            // field to read.
            "isBonded": false,
        ]
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if let name = peripheral.name ?? advertisedName {
            map["name"] = name
        }
        sink(map)
    }
}
