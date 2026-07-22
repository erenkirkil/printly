import CoreBluetooth
import Flutter

/// Owns the `printly/adapter_state` event channel. Seeds the stream on
/// subscribe with the current Core Bluetooth central manager state and
/// mirrors subsequent delegate updates until the Dart listener cancels.
final class AdapterStateStreamHandler: NSObject, FlutterStreamHandler {

    private let central: CentralController
    private var sink: FlutterEventSink?

    init(central: CentralController) {
        self.central = central
        super.init()
    }

    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        // Instantiating the manager triggers an async .unknown →
        // .poweredOn/.poweredOff delegate callback. Emit the current state
        // immediately so late subscribers don't wait for a transition.
        central.ensureManager()
        events(WireCodes.adapterCode(for: central.state))
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func didUpdateState(_ state: CBManagerState) {
        sink?(WireCodes.adapterCode(for: state))
    }

    func detach() {
        sink = nil
    }
}
