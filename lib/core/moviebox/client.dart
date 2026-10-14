import 'dart:convert';

import 'package:http/http.dart' as http;

import 'signer.dart';

/// The MovieBox client, login only.
///
/// **Deliberately narrow.** Search, details and streams are not here yet. What
/// is here is the part that was verified against the live API before it was
/// written in Dart, and nothing else -- because the previous draft of this file
/// carried search, rails, details and streams as well, and none of it could be
/// compiled, so none of it could be trusted.
///
/// The two gates this class exists to clear, both established by measurement
/// rather than by reading someone's source:
///
///   1. **Region.** A bare request gets
///      `403 FORBIDDEN "Service not available in current region"` from every
///      host, from anywhere. Adding `x-client-info` clears it -- and clears it
///      regardless of the real connection IP, which is why no proxy or tunnel
///      is involved here. A spoofed `x-forwarded-for` was tested and changes
///      nothing, so it is deliberately absent.
///
///   2. **Signature.** With `x-client-info` set, the answer becomes
///      `407 "Signature invalid"` until the HMAC-MD5 is right. The algorithm is
///      in [MovieBoxSigner] and has been run against the live endpoint from a
///      Node script: HTTP 200, visitor token, three-month expiry.
class MovieBoxClient {
  MovieBoxClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Round-robin pool. Several are region-varied; `api6sg` failed transport
  /// outright in testing and is kept because it may answer elsewhere.
  static const List<String> _hosts = [
    'https://api6.aoneroom.com',
    'https://api5.aoneroom.com',
    'https://api4.aoneroom.com',
    'https://api4sg.aoneroom.com',
    'https://api3.aoneroom.com',
    'https://api6sg.aoneroom.com',
    'https://api.inmoviebox.com',
  ];

  static const List<int> _retryStatuses = [403, 406, 407, 429, 500, 502, 503, 504];

  /// The identity that clears the region gate. Kept byte-identical to the value
  /// that was proved to work -- the API parses this as one object, so a
  /// reordered or reformatted copy is not the same request.
  static const String _clientInfo =
      '{"package_name":"com.community.oneroom",'
      '"version_name":"4.0.01.0813.03","version_code":50020121,'
      '"os":"android","os_version":"13",'
      '"device_id":"00000000000000000000000000000000","install_store":"ps",'
      '"gaid":"00000000-0000-0000-0000-000000000000","brand":"Redmi",'
      '"model":"23078RKD5C","system_language":"en","net":"NETWORK_WIFI",'
      '"region":"US","timezone":"Asia/Kolkata","sp_code":"40401",'
      '"X-Play-Mode":"2"}';

  static const String _userAgent =
      'com.community.oneroom/50020121 (Linux; U; Android 13; en_US; 23078RKD5C; '
      'Build/TQ2A.230405.003; Cronet/135.0.7012.3)';

  static const String _loginPath =
      '/wefeed-mobile-bff/user-api/visitor-login';

  /// A stream will not play without this header. `pub const STREAM_REFERER`
  /// upstream. Unused at this step -- here so the value is not lost before the
  /// player lands.
  static const String streamReferer = 'https://sportslive.wine';

  void close() => _http.close();

  /// Logs in as a visitor and returns a human-readable summary.
  ///
  /// **Returns a summary, not the token.** The token is a credential and this
  /// app has nowhere safe to keep it yet; a screen that displays one is a
  /// screen that leaks one. The summary carries its shape and expiry, which is
  /// all that is needed to tell a working login from a broken one.
  ///
  /// **No recursion.** The first draft of this method called the shared
  /// `_send()` helper for its login request -- and `_send()` called back into
  /// `ensureToken()`, so the app would have recursed until it crashed. Login
  /// therefore issues its own request, and `_send` exists only for calls that
  /// need a token, which at this step is none.
  Future<String> login() async {
    final lines = <String>[];

    for (int attempt = 0; attempt < _hosts.length; attempt++) {
      final host = _hosts[attempt];
      final url = Uri.parse('$host$_loginPath');

      // "{}" is two bytes, and the signature covers that byte count. Sending no
      // body at all would produce a different canonical string and a 407.
      const body = '{}';

      try {
        final headers = MovieBoxSigner.headers(
          method: 'POST',
          url: url,
          clientInfo: _clientInfo,
          userAgent: _userAgent,
          body: body,
        );

        lines.add('POST $host');
        lines.add('  signature: ${headers['x-tr-signature']}');

        final response = await _http.post(url, headers: headers, body: body);

        lines.add('  HTTP ${response.statusCode}');

        if (_retryStatuses.contains(response.statusCode)) {
          lines.add('  retrying on the next host');
          lines.add('');
          continue;
        }

        if (response.statusCode != 200) {
          lines.add('  body: ${response.body}');
          throw MovieBoxException(lines.join('\n'));
        }

        final decoded = jsonDecode(response.body);
        final data = decoded is Map ? (decoded['data'] ?? decoded) : null;
        final token = data is Map ? data['token'] : null;

        if (token is! String || token.isEmpty) {
          lines.add('  no token in the response');
          throw MovieBoxException(lines.join('\n'));
        }

        // The token is never printed. Only its shape and its exp claim, which
        // is what says whether this is a real session.
        final parts = token.split('.');
        lines.add('  token segments: ${parts.length}');
        lines.add('  token length:   ${token.length} chars');

        final expiry = _expiryOf(token);
        if (expiry != null) {
          final days = expiry.difference(DateTime.now()).inDays;
          lines.add('  expires:        ${expiry.toIso8601String()}');
          lines.add('  valid for:      $days days');
        } else {
          lines.add('  expires:        (no readable exp claim)');
        }

        lines.add('');
        lines.add('Host used: $host');
        return lines.join('\n');
      } catch (err) {
        // A transport failure is worth another host; a parsed rejection above
        // has already been thrown with its context attached.
        lines.add('  error: $err');
        lines.add('');
      }
    }

    throw MovieBoxException(
      'Every host failed.\n\n${lines.join('\n')}',
    );
  }

  /// Reads `exp` out of the JWT payload.
  ///
  /// Not verified: the signature is theirs to check, not ours. This exists only
  /// to report how long the session lasts. `base64Url.normalize` is what makes
  /// an unpadded JWT segment decodable -- the raw segment is often not a
  /// multiple of four characters, and decoding it directly throws.
  static DateTime? _expiryOf(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final exp = payload is Map ? payload['exp'] : null;
      if (exp is int) return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (_) {
      // Reported as "no readable exp claim" rather than treated as a failure:
      // a token without an exp is still a token.
    }
    return null;
  }
}

class MovieBoxException implements Exception {
  final String message;
  const MovieBoxException(this.message);

  @override
  String toString() => message;
}