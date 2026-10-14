import 'dart:convert';

import 'package:http/http.dart' as http;

import 'signer.dart';

/// A title from a search, a rail, or a banner.
class KinoItem {
  /// MovieBox `subjectId`. **A String**, measured -- not an int. The API returns
  /// it quoted, and treating it as numeric is how a request silently asks for
  /// the wrong subject.
  final String id;
  final String title;

  /// Poster URL. Measured: `cover` is an OBJECT (`{url, width, height, ...}`),
  /// not a string. A parser expecting a string gets null and every card renders
  /// its placeholder.
  final String? poster;

  /// Rating on a 0-10 scale. Measured as a STRING on search results
  /// (`"imdbRatingValue": "8.4"`) and absent on banners.
  final double? rating;

  final String? year;

  /// 1 = movie, 2 = series. Drives whether seasons are fetched.
  final int subjectType;

  /// True when the API says there is something to play.
  final bool hasResource;

  const KinoItem({
    required this.id,
    required this.title,
    this.poster,
    this.rating,
    this.year,
    this.subjectType = 1,
    this.hasResource = false,
  });
}

/// A named row of titles: "Trending", "Popular", and so on.
class KinoRail {
  final String title;
  final List<KinoItem> items;
  const KinoRail({required this.title, required this.items});
}

/// One playable source, with the headers it needs.
class KinoStream {
  final String url;
  final String label;
  final int? resolution;

  /// The API will serve only a preview of this one to a visitor token
  /// (`requireMemberType > 0`, `previewSeconds` in the response).
  ///
  /// Carried rather than filtered: it IS playable, just not entirely, and
  /// dropping it would hide content a signed-in build could use.
  final bool preview;

  /// Some hosts refuse a request without a Referer. Carried per-stream rather
  /// than assumed globally.
  final Map<String, String> headers;

  const KinoStream({
    required this.url,
    required this.label,
    this.resolution,
    this.preview = false,
    this.headers = const {},
  });
}

/// A season of a series.
class KinoSeason {
  final int season;
  final int episodeCount;
  const KinoSeason({required this.season, required this.episodeCount});
}

/// The MovieBox API client.
///
/// Every response shape below was **measured against the live API** before this
/// file was written, not inferred from the Rust project this grew out of. That
/// matters more than it sounds: an earlier draft of this client guessed at
/// search's structure and was wrong in three separate ways --
///
///   * `data.results` is a list of RAILS, each with a nested `subjects[]`, not a
///     flat list of titles;
///   * `subjectId` is a quoted String, not a number;
///   * `cover` is an object carrying `url`, not a URL string.
///
/// Each of those fails as an empty screen rather than as an error, which is
/// exactly why they were worth a probe to find.
class MovieBoxClient {
  MovieBoxClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

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

  /// Required on stream requests. `pub const STREAM_REFERER` upstream, and the
  /// reason this app depends on media_kit rather than video_player: the latter
  /// cannot send headers on iOS at all.
  static const String streamReferer = 'https://sportslive.wine';

  String? _token;
  DateTime? _expiry;
  int _activeHost = 0;

  void close() => _http.close();

  bool get _hasValidToken {
    final expiry = _expiry;
    if (_token == null || expiry == null) return false;
    return DateTime.now().add(const Duration(minutes: 1)).isBefore(expiry);
  }

  /// Logs in and caches the visitor token.
  ///
  /// **No recursion.** An earlier draft had this call the shared `_send()`
  /// helper, which called back into this method -- a stack overflow on launch.
  /// Login therefore issues its own request, and `_send` demands a token that
  /// already exists, so the two cannot call each other.
  Future<String> ensureToken() async {
    if (_hasValidToken) return _token!;

    final url = Uri.parse(
      '${_hosts[_activeHost]}/wefeed-mobile-bff/user-api/visitor-login',
    );
    const body = '{}';

    final response = await _http.post(
      url,
      headers: MovieBoxSigner.headers(
        method: 'POST',
        url: url,
        clientInfo: _clientInfo,
        userAgent: _userAgent,
        body: body,
      ),
      body: body,
    );

    if (response.statusCode != 200) {
      throw MovieBoxException(
        'Login failed with HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? (decoded['data'] ?? decoded) : null;
    final token = data is Map ? data['token'] : null;

    if (token is! String || token.isEmpty) {
      throw const MovieBoxException('Login returned no token');
    }

    _token = token;
    _expiry = _expiryOf(token);
    return token;
  }

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
      // A token without a readable exp is still a token; short-lived is the safe
      // assumption and it forces a refresh rather than trusting it.
    }
    return DateTime.now().add(const Duration(hours: 1));
  }

  /// Home rails.
  ///
  /// Measured shape: `data.items[]`, each with `type`, `title`, and EITHER a
  /// `subjects[]` OR a `banner.banners[]` whose entries carry a nested
  /// `subject`. Empty rails are dropped rather than rendered as a heading with
  /// nothing under it.
  Future<List<KinoRail>> home({String tabId = '0', int page = 1}) async {
    final data = await _send(
      'GET',
      '/wefeed-mobile-bff/tab-operating?page=$page&tabId=$tabId&version=',
    );

    final items = data['items'];
    if (items is! List) return const [];

    final rails = <KinoRail>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      final title = item['title']?.toString() ?? '';
      final found = <KinoItem>[];

      final subjects = item['subjects'];
      if (subjects is List) {
        for (final subject in subjects) {
          if (subject is Map) found.add(_itemFromJson(subject));
        }
      }

      // A banner rail's titles are one level deeper, under `subject`.
      final banner = item['banner'];
      if (banner is Map && banner['banners'] is List) {
        for (final entry in (banner['banners'] as List)) {
          if (entry is! Map) continue;
          final subject = entry['subject'];
          if (subject is Map) found.add(_itemFromJson(subject));
        }
      }

      if (found.isEmpty || title.isEmpty) continue;
      rails.add(KinoRail(title: title, items: found));
    }

    return rails;
  }

  /// Search.
  ///
  /// Measured shape: `data.results[]` is a list of RAILS, each with a nested
  /// `subjects[]` -- not a flat list. Flattened here because a search screen
  /// wants one grid, and rail boundaries are noise at that point.
  Future<List<KinoItem>> search(String query, {int page = 1}) async {
    final body = jsonEncode({
      'keyword': query,
      'page': page,
      'perPage': 15,
      'subjectType': 0,
    });

    final data = await _send(
      'POST',
      '/wefeed-mobile-bff/subject-api/search/v2',
      body: body,
    );

    final results = data['results'];
    if (results is! List) return const [];

    final items = <KinoItem>[];
    final seen = <String>{};

    for (final rail in results) {
      if (rail is! Map) continue;
      final subjects = rail['subjects'];
      if (subjects is! List) continue;
      for (final subject in subjects) {
        if (subject is! Map) continue;
        final item = _itemFromJson(subject);
        // The same title appears in more than one rail when the query names a
        // franchise, so a plain flatten would show duplicates.
        if (item.id.isEmpty || !seen.add(item.id)) continue;
        items.add(item);
      }
    }

    return items;
  }

  /// Details for one title, with its seasons when it is a series.
  Future<Map<String, dynamic>> details(String id) async {
    final data = await _send(
      'GET',
      '/wefeed-mobile-bff/subject-api/get?subjectId=$id',
    );

    // `subjectType == 2` is a series. Checked on the value rather than on the
    // presence of a seasons key, because a film can carry an empty one.
    final subjectType = data['subjectType'];
    if (subjectType == 2) {
      try {
        data['__seasons'] = await _send(
          'GET',
          '/wefeed-mobile-bff/subject-api/season-info?subjectId=$id',
        );
      } catch (_) {
        // A series whose season list failed still renders its own details.
        // Losing the episode list is a smaller failure than losing the page.
      }
    }

    return data;
  }

  /// Playable streams for a title, or one episode of it.
  ///
  /// Two independent paths are asked and merged: `play-info/v2` and `resource`.
  /// That is not belt-and-braces -- the upstream client does the same, and it is
  /// why playback survives one of them changing. Either failing is fine; both
  /// failing throws.
  Future<List<KinoStream>> streams(
    String subjectId, {
    int season = 0,
    int episode = 0,
  }) async {
    final streams = <KinoStream>[];
    final seen = <String>{};

    void absorb(Map<String, dynamic> data) {
      // **Measured 2026-10-14, and the two endpoints do NOT agree.** This is the
      // bug that made every title report "No playable sources were returned"
      // while search and home looked perfectly healthy -- both are 200s with
      // real content, and neither parser could see it:
      //
      //   play-info/v2 -> { streams[] }  address under `url`,
      //                                  resolution under `resolutions` ("480")
      //   resource     -> { list[] }     address under `resourceLink`,
      //                                  resolution under `resolution` (480)
      //
      // The old code read only `list`/`items`, so play-info contributed nothing;
      // and it read only `url`/`playUrl.playUrl`, so resource contributed nothing
      // either. Two independent misses that present as one empty list.
      //
      // `sourceUrl` is present on resource entries and is deliberately NOT read:
      // it is a web page (vegamovies.pet/...), not a stream. Feeding it to the
      // player fails as an unplayable source, which is harder to diagnose than
      // an absent one.
      final list = data['streams'] ?? data['list'] ?? data['items'];
      if (list is! List) return;

      for (final raw in list) {
        if (raw is! Map) continue;
        final entry = raw.cast<String, dynamic>();

        final url = _urlOf(entry);
        if (url == null) continue;

        // Deduped on the path without its query: the same stream is offered more
        // than once with different signing parameters.
        final base = url.split('?').first;
        if (!seen.add(base)) continue;

        // `resolutions` is a STRING where `resolution` is an int, so this parses
        // rather than casts -- a cast would drop every play-info stream.
        final rawResolution = entry['resolution'] ?? entry['resolutions'];
        final resolution = rawResolution is int
            ? rawResolution
            : int.tryParse(rawResolution?.toString() ?? '');

        // Not a filter, a preference. `requireMemberType > 0` marks a resource
        // the API will only preview for a visitor token, so a gated 1080p entry
        // sorting above a free 480p one would play for six minutes and stop --
        // a failure with no error in it, which is the worst kind here.
        final requiresMember = entry['requireMemberType'];
        final gated = requiresMember is int && requiresMember > 0;

        streams.add(KinoStream(
          url: url,
          label: [
            resolution != null ? '${resolution}p' : 'auto',
            if (gated) 'preview',
          ].join(' · '),
          resolution: resolution,
          preview: gated,
          headers: const {'Referer': streamReferer},
        ));
      }
    }

    final suffix = (season == 0 && episode == 0) ? '' : '&se=$season&ep=$episode';

    Object? lastError;
    var anySucceeded = false;

    try {
      absorb(await _send(
        'GET',
        '/wefeed-mobile-bff/subject-api/play-info/v2?subjectId=$subjectId$suffix',
      ));
      anySucceeded = true;
    } catch (err) {
      lastError = err;
    }

    try {
      absorb(await _send(
        'GET',
        '/wefeed-mobile-bff/subject-api/resource'
        '?subjectId=$subjectId$suffix&page=1&perPage=20',
      ));
      anySucceeded = true;
    } catch (err) {
      lastError = err;
    }

    if (!anySucceeded) {
      throw MovieBoxException('Neither stream endpoint answered: $lastError');
    }

    // Free before gated, then highest resolution first. The player takes the
    // first it can open, so a preview-only entry must not outrank a full one --
    // it would open, and then stop partway through.
    streams.sort((a, b) {
      if (a.preview != b.preview) return a.preview ? 1 : -1;
      return (b.resolution ?? 0).compareTo(a.resolution ?? 0);
    });
    return streams;
  }

  /// The playable address of one stream entry.
  ///
  /// **Three names, because the two endpoints disagree** and picking one is
  /// wrong for the other. Measured:
  ///
  ///   * `url`          -- play-info/v2's name for it
  ///   * `resourceLink` -- resource's name for it
  ///   * `playUrl.playUrl` -- nested; not in either measured response, kept
  ///                        because it costs one branch and removes a future
  ///                        surprise
  ///
  /// Each candidate is checked for emptiness rather than for null: a field that
  /// is present but blank would otherwise win over a populated fallback and
  /// produce a stream that opens onto nothing.
  ///
  /// `sourceUrl` is NOT a candidate. It sits beside `resourceLink` on resource
  /// entries and is a web page (vegamovies.pet/...), not a media file -- handing
  /// it to the player fails as an unplayable source, which reads as a CDN
  /// problem rather than as a parser one.
  static String? _urlOf(Map<String, dynamic> entry) {
    for (final key in const ['url', 'resourceLink']) {
      final value = entry[key];
      if (value is String && value.isNotEmpty) return value;
    }

    final playUrl = entry['playUrl'];
    if (playUrl is Map) {
      final nested = playUrl['playUrl'];
      if (nested is String && nested.isNotEmpty) return nested;
    }

    return null;
  }

  /// Extracts seasons from a details response.
  ///
  /// A helper rather than more parsing inside [details], so a screen can call
  /// this without knowing the envelope `season-info` returns. That envelope was
  /// NOT measured -- only search and home were -- so this reads several
  /// plausible keys and returns nothing rather than throwing when none match.
  /// A series page with no episode list is a smaller failure than a crash.
  static List<KinoSeason> seasonsOf(Map<String, dynamic> details) {
    final raw = details['__seasons'];
    if (raw is! Map) return const [];

    final list = raw['seasons'] ?? raw['list'] ?? raw['items'];
    if (list is! List) return const [];

    final seasons = <KinoSeason>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final map = entry.cast<String, dynamic>();
      final number = map['season'] ?? map['se'] ?? map['seasonNumber'];
      final season = number is int ? number : int.tryParse('$number') ?? 0;
      if (season <= 0) continue;

      final episodes = map['episodes'] ?? map['episodeList'];
      var count = 0;
      if (episodes is List) {
        count = episodes.length;
      } else {
        final rawCount = map['episodeCount'] ?? map['totalEpisode'];
        count = rawCount is int ? rawCount : int.tryParse('$rawCount') ?? 0;
      }

      seasons.add(KinoSeason(season: season, episodeCount: count));
    }

    seasons.sort((a, b) => a.season.compareTo(b.season));
    return seasons;
  }

  /// One authenticated call, with failover across the host pool.
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    String? body,
  }) async {
    final token = await ensureToken();
    Object? lastError;

    for (int attempt = 0; attempt < _hosts.length; attempt++) {
      final index = (_activeHost + attempt) % _hosts.length;
      final url = Uri.parse(_hosts[index] + path);

      try {
        final headers = MovieBoxSigner.headers(
          method: method,
          url: url,
          clientInfo: _clientInfo,
          userAgent: _userAgent,
          body: body,
        );
        headers['authorization'] = 'Bearer $token';

        final response = method == 'POST'
            ? await _http.post(url, headers: headers, body: body)
            : await _http.get(url, headers: headers);

        if (_retryStatuses.contains(response.statusCode)) {
          lastError = MovieBoxException(
            'HTTP ${response.statusCode} from ${_hosts[index]}: ${response.body}',
          );
          // A rejected token is dropped so the NEXT call re-authenticates. Doing
          // it inline would make failover and re-auth fight over the same state.
          if (response.statusCode == 401 || response.statusCode == 407) {
            _token = null;
            _expiry = null;
          }
          continue;
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          lastError = const MovieBoxException('Response was not an object');
          continue;
        }

        // The host that answered is preferred from here, so a dead host costs
        // one request rather than one per call.
        _activeHost = index;

        if (response.statusCode != 200) {
          throw MovieBoxException(
            'HTTP ${response.statusCode}: ${response.body}',
          );
        }

        final data = decoded['data'];
        return data is Map
            ? Map<String, dynamic>.from(data)
            : decoded.cast<String, dynamic>();
      } catch (err) {
        lastError = err;
      }
    }

    throw MovieBoxException('Every host failed. Last: $lastError');
  }

  /// Parses one subject.
  ///
  /// Field names taken from a measured search response. Note that `subjectId`
  /// arrives QUOTED and `cover` is an object -- the two facts the earlier draft
  /// got wrong, and the two whose failure looks like "no results" rather than
  /// like an error.
  static KinoItem _itemFromJson(Map raw) {
    final map = raw.cast<String, dynamic>();

    String? poster;
    final cover = map['cover'];
    if (cover is Map) {
      poster = cover['url']?.toString();
    } else if (cover is String) {
      // Accepted as a fallback so a change on their side degrades rather than
      // blanking every card.
      poster = cover;
    }

    final subjectType = map['subjectType'];
    final rating = map['imdbRatingValue'] ?? map['rating'];

    return KinoItem(
      id: (map['subjectId'] ?? map['id'] ?? '').toString(),
      title: (map['title'] ?? map['name'] ?? '').toString(),
      poster: poster,
      year: map['releaseDate']?.toString().split('-').first,
      // A STRING in the response ("8.4"), which is why this parses rather than
      // casts -- a cast would throw at runtime on every card.
      rating: rating is num
          ? rating.toDouble()
          : double.tryParse(rating?.toString() ?? ''),
      subjectType: subjectType is int ? subjectType : 1,
      hasResource: map['hasResource'] == true,
    );
  }
}

class MovieBoxException implements Exception {
  final String message;
  const MovieBoxException(this.message);

  @override
  String toString() => message;
}