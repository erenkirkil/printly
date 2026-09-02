/// printly — production-grade thermal printer SDK for Flutter.
///
/// This is the public barrel file. Import it as:
///
/// ```dart
/// import 'package:printly/printly.dart';
/// ```
library;

export 'src/bluetooth/bluetooth_adapter_state.dart';
export 'src/bluetooth/connection_controller.dart' show kDefaultConnectTimeout;
export 'src/bluetooth/scan_controller.dart'
    show kDefaultScanTimeout, kDefaultScanTypes, ScanStrategy;
export 'src/bluetooth/scan_session.dart' show PrintlyScanSession;
export 'src/core/connection_event.dart';
export 'src/core/connection_state.dart';
export 'src/core/connection_type.dart';
export 'src/core/printly_device.dart';
export 'src/core/printly_exception.dart';
export 'src/core/printly_permission_status.dart';
export 'src/network/tcp_printer_transport.dart' show kDefaultWriteTimeout;
export 'src/platform/printly_platform_interface.dart';
export 'src/print/print_config.dart';
export 'src/print/print_job.dart';
export 'src/print/printly_barcode_type.dart';
export 'src/print/printly_charset.dart';
export 'src/print/printly_cut_mode.dart';
export 'src/print/printly_hri_position.dart';
export 'src/print/printly_paper_width.dart';
export 'src/print/printly_qr_error_level.dart';
export 'src/print/printly_text_align.dart';
export 'src/print/printly_text_size.dart';
export 'src/print/printly_text_style.dart';
export 'src/print/printly_unmappable.dart';
export 'src/print/qr_sizing.dart';
export 'src/print/turkish_code_page.dart';
export 'src/printly_base.dart';
export 'src/raster/printly_bitmap.dart';
export 'src/raster/printly_dithering.dart';
export 'src/raster/printly_raster.dart';
