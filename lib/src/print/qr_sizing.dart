import 'printly_qr_error_level.dart';

/// Smart QR module-size calculation.
///
/// ESC/POS lets the caller pick a per-module *dot* size (1–8). Picking it
/// blindly either overflows the paper or wastes space, so [moduleSize] estimates
/// the QR symbol's module count from the payload length and error-correction
/// level, then divides the printable dot width by it (plus a quiet-zone
/// padding) to find the largest dot size that still fits.
///
/// The printer/driver computes the *real* QR version from the data; this only
/// needs a close estimate to choose the dot size, so the capacity table is
/// capped at version 15 (≈520 bytes) which comfortably covers receipt payloads.
///
/// Stable public utility: exported from the package barrel so consumers can
/// tune [PrintJob.qr]'s `maxModuleSize`; covered by semver like the rest of
/// the public API.
abstract final class QrSizing {
  /// Smallest module dot size the printer supports.
  static const int minModuleSize = 1;

  /// Largest module dot size the ESC/POS QR command supports.
  static const int maxSupportedModuleSize = 8;

  /// Default quiet-zone / margin allowance (in module widths) reserved when
  /// fitting the symbol to the paper.
  static const int defaultPadding = 8;

  /// Byte-mode data capacity per version (`1`-indexed) and error level,
  /// `[L, M, Q, H]`. Verified against ISO/IEC 18004 capacity tables.
  static const Map<int, List<int>> _byteCapacity = <int, List<int>>{
    1: <int>[17, 14, 11, 7],
    2: <int>[32, 26, 20, 14],
    3: <int>[53, 42, 32, 24],
    4: <int>[78, 62, 46, 34],
    5: <int>[106, 84, 60, 44],
    6: <int>[134, 106, 74, 58],
    7: <int>[154, 122, 86, 64],
    8: <int>[192, 152, 108, 84],
    9: <int>[230, 180, 130, 98],
    10: <int>[271, 213, 151, 119],
    11: <int>[321, 251, 177, 137],
    12: <int>[367, 287, 203, 155],
    13: <int>[425, 331, 241, 177],
    14: <int>[458, 362, 258, 194],
    15: <int>[520, 412, 292, 220],
  };

  static const int _maxVersion = 15;

  /// Number of modules along one edge of a QR symbol of [version]
  /// (`17 + 4 × version`, e.g. version 1 → 21, version 5 → 37).
  static int moduleCountForVersion(int version) => 17 + 4 * version;

  /// Estimates the smallest QR version that can carry [dataByteCount] bytes at
  /// [errorLevel]. Caps at version 15 for payloads larger than its capacity.
  static int estimateVersion(
    int dataByteCount,
    PrintlyQrErrorLevel errorLevel,
  ) {
    final int column = switch (errorLevel) {
      PrintlyQrErrorLevel.low => 0,
      PrintlyQrErrorLevel.medium => 1,
      PrintlyQrErrorLevel.quartile => 2,
      PrintlyQrErrorLevel.high => 3,
    };
    for (int v = 1; v <= _maxVersion; v++) {
      if (_byteCapacity[v]![column] >= dataByteCount) return v;
    }
    return _maxVersion;
  }

  /// Largest module dot size in `[1, 8]` such that the estimated symbol fits
  /// within [paperDots], reserving [padding] module widths of quiet zone.
  ///
  /// [data] is measured by its code-point count, which equals the number of
  /// bytes the printer stores (one Latin-1 byte per code point). When
  /// [maxModuleSize] is given the result is additionally clamped to it, letting
  /// callers cap the physical size regardless of how much room is available.
  static int moduleSize({
    required String data,
    required PrintlyQrErrorLevel errorLevel,
    required int paperDots,
    int padding = defaultPadding,
    int? maxModuleSize,
  }) {
    final int dataBytes = data.runes.length;
    final int version = estimateVersion(dataBytes, errorLevel);
    final int modules = moduleCountForVersion(version);

    int size = paperDots ~/ (modules + padding);
    if (size < minModuleSize) size = minModuleSize;
    if (size > maxSupportedModuleSize) size = maxSupportedModuleSize;
    if (maxModuleSize != null && size > maxModuleSize) {
      size = maxModuleSize < minModuleSize ? minModuleSize : maxModuleSize;
    }
    return size;
  }
}
