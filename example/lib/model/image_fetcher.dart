import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Downloads image bytes for the "print from a URL" demo.
///
/// Lives in the example, not in printly. A permission declared in a plugin's
/// manifest is merged into every app that depends on it, so putting `INTERNET`
/// in printly would make an offline point-of-sale app look like it phones home
/// just because it prints receipts. `PrintlyRaster.image` takes a `Uint8List`;
/// where those bytes come from is the app's business.
///
/// Uses `dart:io` rather than a package so the example stays dependency-free.
abstract final class ImageFetcher {
  /// Ceiling on the download.
  ///
  /// A 58 mm receipt is 384 dots wide, so anything past a few hundred KB is
  /// detail the printer physically cannot render — and a runaway download on a
  /// handheld would be paid for in battery and data for nothing.
  static const int maxBytes = 4 * 1024 * 1024;

  static const Duration timeout = Duration(seconds: 15);

  /// Fetches [url] and returns its bytes.
  ///
  /// Throws [ArgumentError] for anything that is not an absolute http(s) URL,
  /// and [HttpException] for a non-200 response or an oversized body.
  static Future<Uint8List> fetch(String url) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isAbsolute || !uri.hasAuthority) {
      throw ArgumentError.value(url, 'url', 'is not an absolute URL');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(
        url,
        'url',
        'must be http or https, got "${uri.scheme}"',
      );
    }

    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(timeout);
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      // Checked before downloading when the server declares it, and again
      // while reading for servers that do not.
      if (response.contentLength > maxBytes) {
        throw HttpException(
          'image is ${response.contentLength} bytes, over the '
          '$maxBytes byte limit',
          uri: uri,
        );
      }

      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw HttpException(
            'image exceeds the $maxBytes byte limit',
            uri: uri,
          );
        }
      }
      final Uint8List bytes = builder.takeBytes();
      if (bytes.isEmpty) {
        throw HttpException('the response body was empty', uri: uri);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }
}
