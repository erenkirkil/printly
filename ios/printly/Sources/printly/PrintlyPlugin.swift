import CoreBluetooth
import Flutter
import UIKit

/// iOS entry point for the printly plugin.
///
/// Thin by design: channels are wired to dedicated handlers and a shared
/// `CentralController` owns the single `CBCentralManager` instance so the
/// permission prompt only appears once across adapter-state, scan, and
/// connection usage.
public class PrintlyPlugin: NSObject, FlutterPlugin {

    private let central = CentralController()

    // Held briefly so ARC does not tear the manager down before the system
    // power alert is presented; released after the alert had time to show.
    private var powerAlertManager: CBCentralManager?

    private lazy var adapterStateHandler = AdapterStateStreamHandler(central: central)
    private lazy var scanResultsHandler = ScanResultsStreamHandler(central: central)
    private let connectionEventsHandler = ConnectionEventsStreamHandler()
    private lazy var connectionCoordinator = ConnectionCoordinator(
        central: central,
        events: connectionEventsHandler
    )

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PrintlyPlugin()
        instance.wireCentralObservers()

        let methodChannel = FlutterMethodChannel(
            name: WireCodes.Channels.method,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        FlutterEventChannel(
            name: WireCodes.Channels.adapterState,
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.adapterStateHandler)

        FlutterEventChannel(
            name: WireCodes.Channels.scanResults,
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.scanResultsHandler)

        FlutterEventChannel(
            name: WireCodes.Channels.connectionEvents,
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.connectionEventsHandler)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        // Native resources must not outlive the engine: stop any running
        // scan, tear down live connections, and drop the event sinks.
        scanResultsHandler.detach()
        connectionCoordinator.detach()
        adapterStateHandler.detach()
        connectionEventsHandler.detach()
        central.detach()
    }

    private func wireCentralObservers() {
        central.adapterState = adapterStateHandler
        central.scan = scanResultsHandler
        central.connection = connectionCoordinator
    }

    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case WireCodes.Methods.getPlatformVersion:
            result("iOS " + UIDevice.current.systemVersion)
        case WireCodes.Methods.openBluetoothSettings:
            result(Self.openBluetoothSettings())
        case WireCodes.Methods.requestEnableBluetooth:
            handleRequestEnableBluetooth(result: result)
        case WireCodes.Methods.startScan:
            handleStartScan(call: call, result: result)
        case WireCodes.Methods.stopScan:
            scanResultsHandler.stop()
            result(nil)
        case WireCodes.Methods.connect:
            handleConnect(call: call, result: result)
        case WireCodes.Methods.disconnect:
            handleDisconnect(call: call, result: result)
        case WireCodes.Methods.write:
            handleWrite(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleStartScan(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let rawTypes = args[WireCodes.Keys.types] as? [Any] ?? []
        let types: [Int] = rawTypes.compactMap { ($0 as? NSNumber)?.intValue }
        scanResultsHandler.start(types: types) { outcome in
            switch outcome {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(
                    code: error.flutterCode,
                    message: error.reason,
                    details: nil
                ))
            }
        }
    }

    private func handleConnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let device = args[WireCodes.Keys.device] as? [String: Any] else {
            result(FlutterError(
                code: WireCodes.Reasons.invalidArgs,
                message: "device missing",
                details: nil
            ))
            return
        }
        let timeoutMs = (args[WireCodes.Keys.timeoutMs] as? NSNumber)?.intValue
        connectionCoordinator.connect(payload: device, timeoutMs: timeoutMs)
        result(nil)
    }

    private func handleDisconnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let device = args[WireCodes.Keys.device] as? [String: Any] else {
            result(FlutterError(
                code: WireCodes.Reasons.invalidArgs,
                message: "device missing",
                details: nil
            ))
            return
        }
        connectionCoordinator.disconnect(payload: device)
        result(nil)
    }

    private func handleWrite(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let device = args[WireCodes.Keys.device] as? [String: Any] else {
            result(FlutterError(
                code: WireCodes.Reasons.invalidArgs,
                message: "device missing",
                details: nil
            ))
            return
        }
        guard let data = args[WireCodes.Keys.bytes] as? FlutterStandardTypedData else {
            result(FlutterError(
                code: WireCodes.Reasons.invalidArgs,
                message: "bytes missing",
                details: nil
            ))
            return
        }
        connectionCoordinator.write(payload: device, bytes: data.data) { reason in
            guard let reason = reason else {
                result(nil)
                return
            }
            // Pass shared-vocabulary reasons through as their own codes so
            // Dart can classify them; anything else collapses to the generic
            // write_failed with the raw reason in the message — byte-for-byte
            // the same mapping as Android's handleWrite.
            let code: String
            switch reason {
            case WireCodes.Reasons.notConnected,
                 WireCodes.Reasons.notReady,
                 WireCodes.Reasons.writeBusy,
                 WireCodes.Reasons.writeTimeout,
                 WireCodes.Reasons.disconnected:
                code = reason
            default:
                code = WireCodes.Reasons.writeFailed
            }
            result(FlutterError(code: code, message: reason, details: nil))
        }
    }

    private func handleRequestEnableBluetooth(result: @escaping FlutterResult) {
        // There is no programmatic "turn Bluetooth on" API on iOS.
        // `CBCentralManager(delegate:queue:options:)` with the show-power-alert
        // option is Apple's only sanctioned "turn it on" prompt — its Settings
        // button legitimately deep-links to the system Bluetooth pane, which
        // `openBluetoothSettings()` cannot do (see its own doc comment).
        //
        // `central.state` reads the shared, lazily-created `CentralController`'s
        // manager *without* instantiating it (`manager?.state ?? .unknown` —
        // see `CentralController.state`), so checking it here never disturbs
        // that controller's lazy-init contract. If no manager has been created
        // yet this reads as `.unknown`, and a power-alert manager is created
        // regardless: when the radio actually is on, CoreBluetooth simply
        // suppresses the alert, so this is harmless — it only ever shows the
        // alert when it is actually warranted.
        if central.state == .poweredOn {
            result(false)
            return
        }
        let manager = CBCentralManager(
            delegate: nil,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        powerAlertManager = manager
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            // Only clear our own instance — a second overlapping request may
            // have replaced it, and its alert must outlive OUR timer.
            if self?.powerAlertManager === manager {
                self?.powerAlertManager = nil
            }
        }
        result(true)
    }

    private static func openBluetoothSettings() -> Bool {
        // iOS has no public deep link to the Bluetooth pane — `App-Prefs:` is
        // a private scheme and an App Store guideline 2.5.1 rejection risk,
        // so the app's own settings page is the closest supported
        // destination. The Dart-side docs state this honestly.
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(settingsURL) else {
            return false
        }
        UIApplication.shared.open(settingsURL)
        return true
    }
}
