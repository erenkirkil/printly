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
            name: "printly",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        FlutterEventChannel(
            name: "printly/adapter_state",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.adapterStateHandler)

        FlutterEventChannel(
            name: "printly/scan_results",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.scanResultsHandler)

        FlutterEventChannel(
            name: "printly/connection_events",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.connectionEventsHandler)
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
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        case "openBluetoothSettings":
            result(Self.openBluetoothSettings())
        case "startScan":
            handleStartScan(call: call, result: result)
        case "stopScan":
            scanResultsHandler.stop()
            result(nil)
        case "connect":
            handleConnect(call: call, result: result)
        case "disconnect":
            handleDisconnect(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleStartScan(call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let args = call.arguments as? [String: Any] ?? [:]
            let rawTypes = args["types"] as? [Any] ?? []
            let types: [Int] = rawTypes.compactMap { ($0 as? NSNumber)?.intValue }
            try scanResultsHandler.start(types: types)
            result(nil)
        } catch {
            result(FlutterError(
                code: "start_scan_failed",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    private func handleConnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let device = args["device"] as? [String: Any] else {
            result(FlutterError(code: "invalid_args", message: "device missing", details: nil))
            return
        }
        let timeoutMs = (args["timeoutMs"] as? NSNumber)?.intValue
        connectionCoordinator.connect(payload: device, timeoutMs: timeoutMs)
        result(nil)
    }

    private func handleDisconnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let device = args["device"] as? [String: Any] else {
            result(FlutterError(code: "invalid_args", message: "device missing", details: nil))
            return
        }
        connectionCoordinator.disconnect(payload: device)
        result(nil)
    }

    private static func openBluetoothSettings() -> Bool {
        // `App-Prefs:Bluetooth` opens the Bluetooth pane inside the Settings
        // app on iOS 13+. Fall back to the app-level settings URL so the
        // user is at least taken somewhere meaningful on unsupported iOS
        // revisions.
        if let prefsURL = URL(string: "App-Prefs:Bluetooth"),
           UIApplication.shared.canOpenURL(prefsURL) {
            UIApplication.shared.open(prefsURL)
            return true
        }
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
            return true
        }
        return false
    }
}
