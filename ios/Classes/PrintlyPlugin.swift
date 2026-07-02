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
        // iOS printing (BLE GATT writes) lands in Sprint 6 alongside the rest
        // of the CoreBluetooth characteristic work. Reject explicitly so the
        // public API exists and callers get a clear, actionable error today.
        result(FlutterError(
            code: WireCodes.Reasons.unsupportedPlatform,
            message: "Printing is not yet implemented on iOS (planned for Sprint 6).",
            details: nil
        ))
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
