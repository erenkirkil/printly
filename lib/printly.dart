/// printly — production-grade thermal printer SDK for Flutter.
///
/// This is the public barrel file. Import it as:
///
/// ```dart
/// import 'package:printly/printly.dart';
/// ```
library;

export 'package:permission_handler/permission_handler.dart'
    show PermissionStatus;

export 'src/bluetooth/bluetooth_adapter_state.dart';
export 'src/core/connection_event.dart';
export 'src/core/connection_state.dart';
export 'src/core/connection_type.dart';
export 'src/core/printly_device.dart';
export 'src/printly_base.dart';
