import CoreBluetooth
import Flutter
import UIKit

/// iOS implementation of the printly plugin.
///
/// Mirrors the channel layout used by the Android plugin:
///   - `printly` MethodChannel — one-shot calls (`getPlatformVersion`,
///     `openBluetoothSettings`).
///   - `printly/adapter_state` EventChannel — broadcast stream of
///     Core Bluetooth central manager state changes.
///
/// The `CBCentralManager` instance is created lazily on the first
/// subscription to the event channel. This is important because
/// instantiating `CBCentralManager` triggers the iOS Bluetooth permission
/// prompt whenever `NSBluetoothAlwaysUsageDescription` is declared in the
/// consumer's Info.plist — we do not want that to happen at app launch.
public class PrintlyPlugin: NSObject, FlutterPlugin {

    // Wire protocol codes, kept in sync with BluetoothAdapterState.fromCode
    // on the Dart side.
    private static let codeUnknown: Int = 0
    private static let codeResetting: Int = 1
    private static let codeUnsupported: Int = 2
    private static let codeUnauthorized: Int = 3
    private static let codePoweredOff: Int = 4
    private static let codePoweredOn: Int = 5

    private let adapterStateHandler = AdapterStateStreamHandler()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "printly",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "printly/adapter_state",
            binaryMessenger: registrar.messenger()
        )

        let instance = PrintlyPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance.adapterStateHandler)
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func openBluetoothSettings() -> Bool {
        // `App-Prefs:Bluetooth` opens the Bluetooth pane inside the
        // Settings app on iOS 13+. If for some reason the URL can't be
        // opened we fall back to the app-level settings URL so the user
        // is at least taken somewhere meaningful.
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

/// Owns the `CBCentralManager` and forwards state changes to the active
/// Flutter event sink.
private final class AdapterStateStreamHandler: NSObject, FlutterStreamHandler,
    CBCentralManagerDelegate {

    private var eventSink: FlutterEventSink?
    private var centralManager: CBCentralManager?

    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        if centralManager == nil {
            // Passing `options: nil` means the init will NOT show the
            // "Your app would like to use Bluetooth" prompt until the
            // manager is actually used, matching permission_handler's
            // behaviour. iOS still reports `.unauthorized` via the
            // delegate callback if the user has denied the permission.
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else if let manager = centralManager {
            events(PrintlyPlugin.encode(state: manager.state))
        }
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        eventSink?(PrintlyPlugin.encode(state: central.state))
    }
}

extension PrintlyPlugin {
    fileprivate static func encode(state: CBManagerState) -> Int {
        switch state {
        case .poweredOn: return codePoweredOn
        case .poweredOff: return codePoweredOff
        case .unauthorized: return codeUnauthorized
        case .unsupported: return codeUnsupported
        case .resetting: return codeResetting
        case .unknown: return codeUnknown
        @unknown default: return codeUnknown
        }
    }
}
