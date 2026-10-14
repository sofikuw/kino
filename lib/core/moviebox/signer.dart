import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The MovieBox request signature.
///
/// This is a port of `src/providers/moviebox/crypto.rs` from
/// mesamirh/MovieBox-Tui, and it was **verified against the live API** before
/// being written in Dart: a Node implementation of exactly this algorithm
/// returns `HTTP 200` and a visitor token. So the constants, the field order and
/// the odd reversed-timestamp client token are measured facts here, not
/// inference from someone's source.
///
/// The algorithm:
///
/// ```
/// x-client-token = "<ts_ms>,<md5hex(reverse(str(ts_ms)))>"
/// x-tr-signature = "<ts_ms>|2|<base64(hmacMd5(secret, canonical))>"
///
/// canonical = join("\n", [
///   METHOD.toUpperCase(),
///   accept,
///   content-type,
///   body_length,                  // decimal BYTE count; "" when no body
///   ts_ms,
///   md5hex(body[0..102400]),      // "" when no body
///   "/path?sorted_query",         // query sorted by key
/// ])
/// ```
///
/// **HMAC-MD5, not SHA-256.** `package:crypto` exports `Hmac` for the SHA family
/// only, so MD5 HMAC is built here from the raw `Md5` digest. That is the one
/// genuinely awkward part of this port and the reason this file exists rather
/// than a call to a library helper.
///
/// **The secret is a constant.** It was published in the upstream source. It can
/// be rotated by the service at any time, and when it is, this client stops
/// working until someone updates this string. That is a property of the
/// approach, not a bug to fix.
class MovieBoxSigner {
  /// 32 bytes, transcribed as hex from the Rust byte-string literal. Hex rather
  /// than escapes because a single wrong byte here fails as a bare
  /// "Signature invalid" with nothing to point at it.
  static const String _secretHex =
      'efa891974eecd3148df63aa611602defd101259ba521022c57ae0566bd8e';

  /// Only the first 100 KiB of a body is digest-covered. From the Rust source.
  static const int _bodyDigestLimit = 102400;

  static Uint8List get _secret {
    return Uint8List.fromList([
      for (int i = 0; i < _secretHex.length; i += 2)
        int.parse(_secretHex.substring(i, i + 2), radix: 16),
    ]);
  }

  static String md5Hex(List<int> bytes) =>
      crypto.md5.convert(bytes).toString();

  /// HMAC-MD5, built from the digest rather than from `Hmac`.
  ///
  /// RFC 2104: `H(md5, k' XOR opad || md5(k' XOR ipad || message))`, with the
  /// key zero-padded (or hashed, if longer than the 64-byte block).
  static List<int> hmacMd5(List<int> key, List<int> message) {
    const int blockSize = 64;

    var normalized = key;
    if (normalized.length > blockSize) {
      normalized = crypto.md5.convert(normalized).bytes;
    }
    if (normalized.length < blockSize) {
      normalized = [
        ...normalized,
        ...List<int>.filled(blockSize - normalized.length, 0),
      ];
    }

    final ipad = [for (final byte in normalized) byte ^ 0x36];
    final opad = [for (final byte in normalized) byte ^ 0x5c];

    final inner = crypto.md5.convert([...ipad, ...message]).bytes;
    return crypto.md5.convert([...opad, ...inner]).bytes;
  }

  /// Query params sorted by key, values in original order.
  ///
  /// Ordering is load-bearing: a different order changes the canonical string,
  /// and the API cannot tell the difference between that and a wrong secret.
  static String _sortedQuery(Uri uri) {
    final params = <String, List<String>>{};
    for (final entry in uri.queryParametersAll.entries) {
      params[entry.key] = [...entry.value];
    }

    final keys = params.keys.toList()..sort();
    final parts = <String>[];
    for (final key in keys) {
      for (final value in params[key]!) {
        parts.add('$key=$value');
      }
    }
    return parts.join('&');
  }

  static String _canonicalUrl(Uri uri) {
    final query = _sortedQuery(uri);
    return query.isEmpty ? uri.path : '${uri.path}?$query';
  }

  /// The exact string the HMAC is taken over. Returned for diagnostics --
  /// when the API says only "Signature invalid", this is the sole thing that
  /// can be inspected.
  static String buildCanonical({
    required String method,
    required String accept,
    required String contentType,
    required Uri url,
    String? body,
    required int timestampMs,
  }) {
    String bodyHash = '';
    String bodyLength = '';

    if (body != null) {
      final bytes = utf8.encode(body);
      final covered = bytes.length > _bodyDigestLimit
          ? bytes.sublist(0, _bodyDigestLimit)
          : bytes;
      bodyHash = md5Hex(covered);
      // The BYTE count, not the character count. For "{}" those agree, which is
      // exactly why getting it wrong is easy and silent.
      bodyLength = bytes.length.toString();
    }

    return [
      method.toUpperCase(),
      accept,
      contentType,
      bodyLength,
      timestampMs.toString(),
      bodyHash,
      _canonicalUrl(url),
    ].join('\n');
  }

  /// The signed header set for one request.
  static Map<String, String> headers({
    required String method,
    required Uri url,
    required String clientInfo,
    required String userAgent,
    String? body,
    int? timestampMs,
  }) {
    const accept = 'application/json';
    const contentType = 'application/json';

    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;

    // The digits of the timestamp, reversed. Deliberate upstream, and not a
    // transcription error here.
    final reversed = ts.toString().split('').reversed.join();
    final clientToken = '$ts,${md5Hex(utf8.encode(reversed))}';

    final canonical = buildCanonical(
      method: method,
      accept: accept,
      contentType: contentType,
      url: url,
      body: body,
      timestampMs: ts,
    );

    final signatureBytes = hmacMd5(_secret, utf8.encode(canonical));
    final signature = '$ts|2|${base64.encode(signatureBytes)}';

    return {
      'accept': accept,
      'content-type': contentType,
      'user-agent': userAgent,
      // Clears the API's region gate. Measured: without it every host answers
      // `403 FORBIDDEN "Service not available in current region"`, and with it
      // they answer 200 -- from anywhere. The API trusts this header over the
      // real connection IP, which is why no tunnel or proxy is needed.
      'x-client-info': clientInfo,
      'x-client-status': '0',
      'x-client-token': clientToken,
      'x-tr-signature': signature,
    };
  }
}