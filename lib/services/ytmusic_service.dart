// lib/services/ytmusic_service.dart
// Communicates with the YouTube Music Innertube API (no API key required).
// All public methods are async, never throw to the caller, and cache results
// in memory for 30 minutes.
//
// Caching
// ─────────────────────────────────────────────────────────────
//   L1  in-memory Map, 30-minute freshness  (instant, lost on restart)
//   L2  Hive-backed feed cache, unbounded     (Android only, survives restarts)
//
//   Reads are stale-while-revalidate: a fresh L1 entry returns immediately
//   and never touches the network; a stale L1 or L2 entry returns straight
//   away and kicks off a background refresh whose result is published on
//   [revisions] so a provider that already rendered the stale value can patch
//   itself. Only a complete miss blocks on the network.
//
//   Desktop keeps the previous behaviour: L1 only, blocking refresh.
// ------------------------------------------------------------

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../models/ytmusic_models.dart';
import '../utils/thumbnail_url.dart';
import 'ytmusic_feed_cache.dart';

// ---------------------------------------------------------------------------
// Internal cache entry
// ---------------------------------------------------------------------------

class _CacheEntry {
  final Object data;

  /// Encoded form of [data], kept so a background refresh can be compared
  /// against what was served without re-encoding (and without relying on
  /// `==`, which is identity for lists).
  final String fingerprint;

  final DateTime expiresAt;

  _CacheEntry(this.data, this.fingerprint, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// What the last read for a key handed to the caller, plus its fingerprint.
class _Served {
  final Object value;
  final String fingerprint;

  const _Served(this.value, this.fingerprint);
}

/// True when a freshly fetched payload should not be cached because the
/// request effectively failed (an empty list, an empty body).
bool _isEmptyPayload(Object value) => value is Iterable && value.isEmpty;


// ---------------------------------------------------------------------------
// YtMusicService
// ---------------------------------------------------------------------------

class YtMusicService {
  YtMusicService._();
  static final YtMusicService instance = YtMusicService._();

  // ── HTTP constants ─────────────────────────────────────────────────────────

  static const String _baseUrl = 'https://music.youtube.com/youtubei/v1/';

  // Client version must be current; YouTube rejects stale versions with empty
  // or degraded responses.  Update this value if you see HTTP 200 but empty
  // sectionListRenderer.contents.
  static const String _clientVersion = '1.20250101.01.00';

  static const Map<String, dynamic> _clientContext = {
    'context': {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': _clientVersion,
        'hl': 'en',
        'gl': 'US',
        'userAgent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      },
    },
  };

  // Static headers (X-Goog-Visitor-Id is added dynamically after fetch).
  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': _clientVersion,
    };
    if (_visitorId != null) {
      h['X-Goog-Visitor-Id'] = _visitorId!;
    }
    return h;
  }

  // ── Visitor ID ─────────────────────────────────────────────────────────────
  // YouTube Music requires a valid visitor-id (obtained by hitting the home
  // page with a GET request) to return non-empty personalised feeds.

  String? _visitorId;
  bool _visitorIdFetchStarted = false;

  Future<void> _ensureVisitorId() async {
    if (_visitorId != null) return;
    if (_visitorIdFetchStarted) {
      // Another call is already fetching — wait briefly then return
      await Future.delayed(const Duration(milliseconds: 600));
      return;
    }
    _visitorIdFetchStarted = true;
    try {
      final response = await http
          .get(
            Uri.parse('https://music.youtube.com/'),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 10));

      // The visitor ID appears in the Set-Cookie header or in the response body
      // as "visitorData":"..." or "X-Goog-Visitor-Id: ..."
      final body = response.body;

      // Try to find it in the page source (ytcfg.set({...VISITOR_DATA...}))
      final RegExp visitorRe = RegExp(r'"visitorData"\s*:\s*"([^"]+)"');
      final match = visitorRe.firstMatch(body);
      if (match != null) {
        _visitorId = match.group(1);
        debugPrint('[YtMusicService] visitorId fetched: $_visitorId');
        return;
      }

      // Fall back to Set-Cookie
      final setCookie = response.headers['set-cookie'] ?? '';
      final cookieRe = RegExp(r'VISITOR_INFO1_LIVE=([^;]+)');
      final cookieMatch = cookieRe.firstMatch(setCookie);
      if (cookieMatch != null) {
        _visitorId = cookieMatch.group(1);
        debugPrint(
            '[YtMusicService] visitorId from cookie: $_visitorId');
        return;
      }

      // Nothing found — proceed without it (feed will still load, just not
      // personalised).
      debugPrint('[YtMusicService] visitorId not found; proceeding without.');
    } catch (e) {
      debugPrint('[YtMusicService] _ensureVisitorId error: $e');
    }
  }

  // ── Feed cache keys ───────────────────────────────────────────────────────
  // Public so providers can subscribe to background updates for the same entry
  // a read used. Every public getter below builds its key through these.

  static const String kHomeFeedKey = 'home_feed';
  static const String kExploreKey = 'explore';
  static const String kMoodsGenresKey = 'moods_genres';
  static const String kAlbumsForYouKey = 'albums_for_you';
  static String homeMoodKey(String params) => 'home_mood_$params';
  static String searchKey(String query) =>
      'search_${query.toLowerCase().trim()}';
  static String artistSongsKey(String browseId) => 'artist_songs_$browseId';
  static String relatedArtistsKey(String browseId) =>
      'related_artists_$browseId';
  static String upNextKey(String videoId) => 'upnext_$videoId';
  static String albumTracksKey(String browseId) => 'album_tracks_$browseId';

  // ── L1: in-memory cache ───────────────────────────────────────────────────

  final Map<String, _CacheEntry> _cache = {};

  /// What each key last handed out, used to decide whether a background
  /// refresh actually changed anything.
  final Map<String, _Served> _served = {};

  /// Keys with a refresh already in flight, so N callers do not cause N
  /// network requests.
  final Set<String> _revalidating = {};

  /// Per-key update channels for background revalidations.
  final Map<String, StreamController<dynamic>> _revisions = {};

  /// How long a fetched feed stays fresh in L1.
  static const Duration _kFeedTtl = Duration(minutes: 30);

  void _putCache(String key, Object data, String fingerprint) {
    _cache[key] = _CacheEntry(
      data,
      fingerprint,
      DateTime.now().add(_kFeedTtl),
    );
  }

  // ── Revisions ─────────────────────────────────────────────────────────────

  /// Emits whenever a background refresh for [key] completes and the payload
  /// differs from what the previous read returned.
  ///
  /// Subscribe *before* awaiting the corresponding getter. A revision that
  /// lands during the initial await would otherwise be lost, leaving the
  /// screen stuck on the stale value until the next load:
  ///
  /// ```dart
  /// var gotRevision = false;
  /// final sub = service.revisions<List<YtSong>>(key).listen((v) {
  ///   gotRevision = true;
  ///   apply(v);
  /// });
  /// final value = await service.getArtistTopSongs(id);
  /// if (!gotRevision) apply(value);
  /// ```
  Stream<T> revisions<T extends Object>(String key) {
    final controller = _revisions.putIfAbsent(
      key,
      () => StreamController<dynamic>.broadcast(),
    );
    return controller.stream.cast<T>();
  }

  void _publishRevision(String key, Object value) {
    try {
      final controller = _revisions[key];
      if (controller == null || controller.isClosed) return;
      // Nobody is watching — the reader already has this value in hand.
      if (!controller.hasListener) return;
      controller.add(value);
    } catch (e) {
      debugPrint('[YtMusicService] revision publish failed for $key: $e');
    }
  }

  // ── Stale-while-revalidate ────────────────────────────────────────────────

  /// Reads [key], preferring the freshest tier available, and revalidates in
  /// the background whenever it served something that was not L1-fresh.
  ///
  /// [encode] / [decode] are supplied by the caller because every feed has a
  /// different value type. An encoder may return either a map (for structured
  /// feeds) or a bare list; both are stored under one uniform envelope.
  ///
  /// [cacheEmpty] preserves the per-feed policy of the original inline
  /// caching — a few feeds must not be allowed to poison the cache with an
  /// empty result when the network call fails.
  Future<T> _swr<T extends Object>(
    String key,
    Future<T> Function() fetch, {
    required Object? Function(T value) encode,
    required T Function(dynamic json) decode,
    bool cacheEmpty = true,
  }) async {
    // ── L1, still fresh: no network at all ──────────────────────────────────
    final entry = _cache[key];
    if (entry != null && !entry.isExpired) {
      final value = entry.data as T;
      _served[key] = _Served(value, entry.fingerprint);
      return value;
    }

    // ── L1, expired: serve it now, refresh behind the user's back ───────────
    if (entry != null) {
      final stale = entry.data as T;
      _served[key] = _Served(stale, entry.fingerprint);
      _startRevalidate<T>(key, fetch, encode, cacheEmpty);
      return stale;
    }

    // ── L2, disk (Android only) ─────────────────────────────────────────────
    final disk = await _readFeedCache<T>(key, decode);
    if (disk != null) {
      final value = disk.$1;
      final fingerprint = disk.$2;
      _putCache(key, value, fingerprint);
      _served[key] = _Served(value, fingerprint);
      _startRevalidate<T>(key, fetch, encode, cacheEmpty);
      debugPrint('[YtMusicService] $key served from disk, refreshing');
      return value;
    }

    // ── Cold miss: the only case that waits on the network ─────────────────
    return _fetchAndStore<T>(key, fetch, encode, cacheEmpty);
  }

  Future<T> _fetchAndStore<T extends Object>(
    String key,
    Future<T> Function() fetch,
    Object? Function(T value) encode,
    bool cacheEmpty,
  ) async {
    final value = await fetch();
    final fingerprint = _store<T>(key, value, encode, cacheEmpty);
    _served[key] = _Served(value, fingerprint);
    return value;
  }

  void _startRevalidate<T extends Object>(
    String key,
    Future<T> Function() fetch,
    Object? Function(T value) encode,
    bool cacheEmpty,
  ) {
    if (_revalidating.contains(key)) return;
    _revalidating.add(key);
    unawaited(() async {
      try {
        final fresh = await fetch();
        final fingerprint = _store<T>(key, fresh, encode, cacheEmpty);
        // The value stored even if it is empty; only publish when it differs
        // from what the reader is currently showing.
        final previous = _served[key];
        if (previous == null || previous.fingerprint != fingerprint) {
          _served[key] = _Served(fresh, fingerprint);
          _publishRevision(key, fresh);
          debugPrint('[YtMusicService] $key revalidated with new content');
        } else {
          debugPrint('[YtMusicService] $key revalidated, unchanged');
        }
      } catch (e) {
        debugPrint('[YtMusicService] revalidation failed for $key: $e');
      } finally {
        _revalidating.remove(key);
      }
    }());
  }

  /// Caches [value] in both tiers and returns the fingerprint used for change
  /// detection. Encoding happens exactly once per fetch.
  ///
  /// Returns an empty fingerprint when the value was deliberately not cached —
  /// callers treat that as "nothing to publish".
  String _store<T extends Object>(
    String key,
    T value,
    Object? Function(T value) encode,
    bool cacheEmpty,
  ) {
    if (!cacheEmpty && _isEmptyPayload(value)) return '';
    try {
      final payload = _asPayload(encode(value));
      final fingerprint = jsonEncode(payload);
      _putCache(key, value, fingerprint);
      unawaited(YtMusicFeedCache.instance.write(key, payload));
      return fingerprint;
    } catch (e) {
      // A serialisation bug must not lose the value; keep it in memory only.
      debugPrint('[YtMusicService] encode failed for $key: $e');
      _putCache(key, value, '');
      return '';
    }
  }

  /// Normalises whatever an encoder produced into a single JSON object, so
  /// the stored shape is uniform: list feeds land under `items`.
  static Map<String, dynamic> _asPayload(Object? encoded) {
    if (encoded is Map) return Map<String, dynamic>.from(encoded);
    return {'items': encoded};
  }

  /// Loads a feed from disk. Returns `(value, fingerprint)` or null.
  Future<(T, String)?> _readFeedCache<T extends Object>(
    String key,
    T Function(dynamic json) decode,
  ) async {
    if (!YtMusicFeedCache.instance.isEnabled) return null;
    try {
      final payload = await YtMusicFeedCache.instance.read(key);
      if (payload == null) return null;
      final value = decode(payload);
      return (value, jsonEncode(payload));
    } catch (e) {
      debugPrint('[YtMusicService] disk decode failed for $key: $e');
      return null;
    }
  }

  // ── Low-level POST ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _post(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    await _ensureVisitorId();
    final uri = Uri.parse('$_baseUrl$endpoint?prettyPrint=false');
    final merged = <String, dynamic>{
      ..._clientContext,
      ...body,
    };
    try {
      final response = await http
          .post(uri, headers: _headers, body: jsonEncode(merged))
          .timeout(const Duration(seconds: 20));

      debugPrint(
          '[YtMusicService] POST $endpoint → HTTP ${response.statusCode} '
          '(${response.bodyBytes.length} bytes)');

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        debugPrint('[YtMusicService] Unexpected JSON type for $endpoint');
      } else {
        debugPrint(
            '[YtMusicService] Error body (first 400): '
            '${response.body.substring(0, response.body.length.clamp(0, 400))}');
      }
    } catch (e) {
      debugPrint('[YtMusicService] POST error ($endpoint): $e');
    }
    return null;
  }

  // ── Navigation helper ──────────────────────────────────────────────────────

  /// Safely drill into nested maps by [path]. Returns null on any mismatch.
  T? _nav<T>(dynamic root, List<Object> path) {
    dynamic cur = root;
    for (final key in path) {
      if (key is int) {
        if (cur is! List || key >= cur.length) return null;
        cur = cur[key];
      } else if (key is String) {
        if (cur is! Map) return null;
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur is T ? cur : null;
  }

  // ── Text helpers ───────────────────────────────────────────────────────────

  /// Concatenates all run texts from a `runs` list, or returns empty string.
  String _runs(dynamic obj) {
    if (obj == null) return '';
    final runs = obj['runs'];
    if (runs is! List) return '';
    final buffer = StringBuffer();
    for (final run in runs) {
      if (run is Map) {
        final text = run['text'];
        if (text is String) buffer.write(text);
      }
    }
    return buffer.toString().trim();
  }

  // ── Thumbnail helper ───────────────────────────────────────────────────────

  /// Picks the best square thumbnail URL from a list of thumbnail objects.
  /// Prefers 544×544 or 226×226; falls back to the largest one found.
  /// Normalizes protocol-relative URLs and optimizes Google CDN sizes.
  String _thumb(dynamic thumbnails) {
    if (thumbnails is! List || thumbnails.isEmpty) return '';

    String? best;
    int bestSize = -1;

    for (final t in thumbnails) {
      if (t is! Map) continue;
      final url = t['url'];
      if (url is! String || url.isEmpty) continue;
      final w = t['width'] is int ? t['width'] as int : 0;
      final h = t['height'] is int ? t['height'] as int : 0;
      // Exact match for the preferred square size (544 or 226)
      if ((w == 544 && h == 544) || (w == 226 && h == 226)) {
        return ThumbnailUrl.normalize(url);
      }
      // Otherwise keep the largest thumbnail we've seen
      final area = w * h;
      if (area > bestSize) {
        bestSize = area;
        best = url;
      }
    }
    return best != null ? ThumbnailUrl.normalize(best) : '';
  }

  /// Extracts the thumbnail list from a standard `thumbnail` wrapper.
  String _thumbFromWrapper(dynamic wrapper) {
    if (wrapper is Map) {
      final inner = wrapper['musicThumbnailRenderer'] ??
          wrapper['thumbnails'] ??
          wrapper['thumbnail'];
      if (inner is Map) return _thumbFromWrapper(inner);
      if (inner is List) return _thumb(inner);
    }
    if (wrapper is List) return _thumb(wrapper);
    return '';
  }

  // ── Duration helper ────────────────────────────────────────────────────────

  Duration _parseDuration(String? text) {
    if (text == null || text.isEmpty) return Duration.zero;
    try {
      final parts = text.split(':').map(int.parse).toList();
      if (parts.length == 2) {
        return Duration(minutes: parts[0], seconds: parts[1]);
      } else if (parts.length == 3) {
        return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
      }
    } catch (_) {}
    return Duration.zero;
  }

  // ── Quality / junk filter ──────────────────────────────────────────────────

  static const List<String> _junkKeywords = [
    'jukebox',
    'mashup',
    'no copyright',
    '1 hour',
    'compilation',
    'slowed',
    'reverb',
    'nightcore',
  ];

  bool _isJunk(String title) {
    final lower = title.toLowerCase();
    for (final kw in _junkKeywords) {
      if (lower.contains(kw)) return true;
    }
    return false;
  }

  bool _songPassesFilter(YtSong song) {
    if (_isJunk(song.title)) { return false; }
    if (song.duration != Duration.zero &&
        song.duration > const Duration(minutes: 10)) { return false; }
    return true;
  }

  // ── Renderer parsers ───────────────────────────────────────────────────────

  /// Parse a `musicResponsiveListItemRenderer` into a [YtSong].
  YtSong? _parseSongFromResponsive(Map<String, dynamic> r) {
    try {
      String? videoId = _nav<String>(r, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId'
      ]);
      videoId ??= _nav<String>(r, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
        0,
        'navigationEndpoint',
        'watchEndpoint',
        'videoId'
      ]);
      videoId ??= _nav<String>(r, ['playlistItemData', 'videoId']);
      videoId ??=
          _nav<String>(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']);

      if (videoId == null || videoId.isEmpty) return null;

      final titleObj = _nav<Map>(r, [
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text'
      ]);
      final title = _runs(titleObj);
      if (title.isEmpty) return null;

      final subtitleObj = _nav<Map>(r, [
        'flexColumns',
        1,
        'musicResponsiveListItemFlexColumnRenderer',
        'text'
      ]);
      final subtitleRuns = subtitleObj?['runs'];
      String artist = '';
      String? album;
      String durationText = '';

      if (subtitleRuns is List) {
        final texts = <String>[];
        for (final run in subtitleRuns) {
          if (run is Map) {
            final text = run['text'];
            if (text is String &&
                text.trim().isNotEmpty &&
                text.trim() != '•') {
              texts.add(text.trim());
            }
          }
        }
        if (texts.isNotEmpty) artist = texts[0];
        final thirdCol = _nav<Map>(r, [
          'flexColumns',
          2,
          'musicResponsiveListItemFlexColumnRenderer',
          'text'
        ]);
        durationText = _runs(thirdCol);
        if (texts.length >= 2 &&
            !RegExp(r'^\d+:\d+').hasMatch(texts[1])) {
          album = texts[1];
        }
      }

      final thumbWrapper = r['thumbnail'];
      var coverUrl = _thumbFromWrapper(thumbWrapper);
      coverUrl = ThumbnailUrl.normalize(coverUrl, videoId: videoId);
      final duration =
          _parseDuration(durationText.isNotEmpty ? durationText : null);

      return YtSong(
        videoId: videoId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        duration: duration,
      );
    } catch (e) {
      debugPrint('[YtMusicService] _parseSongFromResponsive error: $e');
      return null;
    }
  }

  /// Parse a `musicTwoRowItemRenderer` into a [YtSong] (used in carousels).
  YtSong? _parseSongFromTwoRow(Map<String, dynamic> r) {
    try {
      String? videoId =
          _nav<String>(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']);
      videoId ??= _nav<String>(r, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId'
      ]);

      if (videoId == null || videoId.isEmpty) return null;

      final titleObj = r['title'];
      final title = _runs(titleObj);
      if (title.isEmpty) return null;

      final subtitleObj = r['subtitle'];
      final subtitleText = _runs(subtitleObj);
      String artist = subtitleText;
      if (subtitleText.contains(' • ')) {
        artist = subtitleText.split(' • ').last.trim();
      }

      final thumbWrapper = r['thumbnailRenderer'] ?? r['thumbnail'];
      var coverUrl = _thumbFromWrapper(thumbWrapper);
      coverUrl = ThumbnailUrl.normalize(coverUrl, videoId: videoId);

      return YtSong(
        videoId: videoId,
        title: title,
        artist: artist,
        album: null,
        coverUrl: coverUrl,
        duration: Duration.zero,
      );
    } catch (e) {
      debugPrint('[YtMusicService] _parseSongFromTwoRow error: $e');
      return null;
    }
  }

  /// Parse a `musicTwoRowItemRenderer` into a [YtAlbum].
  YtAlbum? _parseAlbumFromTwoRow(Map<String, dynamic> r) {
    try {
      final browseId =
          _nav<String>(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']);
      if (browseId == null || browseId.isEmpty) return null;

      final titleObj = r['title'];
      final title = _runs(titleObj);
      if (title.isEmpty) return null;

      final subtitleObj = r['subtitle'];
      final subtitleText = _runs(subtitleObj);
      String artist = '';
      int? year;
      YtAlbumType albumType = YtAlbumType.unknown;

      final parts = subtitleText.split(' • ');
      for (final part in parts) {
        final trimmed = part.trim();
        final parsed = int.tryParse(trimmed);
        if (parsed != null && parsed > 1900 && parsed < 2200) {
          year = parsed;
        } else if (trimmed.toLowerCase() == 'album') {
          albumType = YtAlbumType.album;
        } else if (trimmed.toLowerCase() == 'single') {
          albumType = YtAlbumType.single;
        } else if (trimmed.toLowerCase() == 'ep') {
          albumType = YtAlbumType.ep;
        } else if (trimmed.isNotEmpty) {
          if (artist.isEmpty) artist = trimmed;
        }
      }

      // Check for explicit badge in subtitleBadges
      bool isExplicit = false;
      final subtitleBadges = r['subtitleBadges'];
      if (subtitleBadges is List) {
        for (final badge in subtitleBadges) {
          if (badge is! Map) continue;
          final badgeRenderer = badge['musicInlineBadgeRenderer'];
          if (badgeRenderer is Map) {
            final iconType = _nav<String>(
                badgeRenderer, ['icon', 'iconType']);
            if (iconType == 'MUSIC_EXPLICIT_BADGE') {
              isExplicit = true;
              break;
            }
          }
        }
      }

      final thumbWrapper = r['thumbnailRenderer'] ?? r['thumbnail'];
      final coverUrl = _thumbFromWrapper(thumbWrapper);

      return YtAlbum(
        browseId: browseId,
        title: title,
        artist: artist,
        coverUrl: coverUrl,
        year: year,
        type: albumType,
        isExplicit: isExplicit,
      );
    } catch (e) {
      debugPrint('[YtMusicService] _parseAlbumFromTwoRow error: $e');
      return null;
    }
  }

  /// Parse a `musicTwoRowItemRenderer` into a [YtArtist].
  YtArtist? _parseArtistFromTwoRow(Map<String, dynamic> r) {
    try {
      final browseId =
          _nav<String>(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']);
      if (browseId == null || browseId.isEmpty) return null;

      final titleObj = r['title'];
      final name = _runs(titleObj);
      if (name.isEmpty) return null;

      final thumbWrapper = r['thumbnailRenderer'] ?? r['thumbnail'];
      final pictureUrl = _thumbFromWrapper(thumbWrapper);

      return YtArtist(browseId: browseId, name: name, pictureUrl: pictureUrl);
    } catch (e) {
      debugPrint('[YtMusicService] _parseArtistFromTwoRow error: $e');
      return null;
    }
  }

  /// Parse a `musicTwoRowItemRenderer` into a [YtPlaylist].
  YtPlaylist? _parsePlaylistFromTwoRow(Map<String, dynamic> r) {
    try {
      String? browseId =
          _nav<String>(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']);
      browseId ??= _nav<String>(r, [
        'navigationEndpoint',
        'watchPlaylistEndpoint',
        'playlistId'
      ]);

      if (browseId == null || browseId.isEmpty) return null;

      final titleObj = r['title'];
      final title = _runs(titleObj);
      if (title.isEmpty) return null;

      final subtitleObj = r['subtitle'];
      final subtitle = _runs(subtitleObj);

      final thumbWrapper = r['thumbnailRenderer'] ?? r['thumbnail'];
      final coverUrl = _thumbFromWrapper(thumbWrapper);

      return YtPlaylist(
        browseId: browseId,
        title: title,
        subtitle: subtitle,
        coverUrl: coverUrl,
      );
    } catch (e) {
      debugPrint('[YtMusicService] _parsePlaylistFromTwoRow error: $e');
      return null;
    }
  }

  // ── Shelf / section parsing ────────────────────────────────────────────────

  _ShelfType _detectShelfType(List<dynamic> items) {
    for (final item in items) {
      if (item is! Map) continue;
      final twoRow = item['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        final endpoint =
            _nav<Map>(twoRow, ['navigationEndpoint', 'browseEndpoint']);
        if (endpoint != null) {
          final pageType = _nav<String>(endpoint, [
            'browseEndpointContextSupportedConfigs',
            'browseEndpointContextMusicConfig',
            'pageType'
          ]);
          if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') { return _ShelfType.artist; }
          if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
              pageType == 'MUSIC_PAGE_TYPE_SINGLE') { return _ShelfType.album; }
          if (pageType == 'MUSIC_PAGE_TYPE_PLAYLIST') {
            return _ShelfType.playlist;
          }
        }
        final watchId = _nav<String>(
            twoRow, ['navigationEndpoint', 'watchEndpoint', 'videoId']);
        if (watchId != null) { return _ShelfType.song; }
      }
      if (item['musicResponsiveListItemRenderer'] != null) {
        return _ShelfType.song;
      }
    }
    return _ShelfType.song;
  }

  YtSection _parseShelf(Map<String, dynamic> shelf) {
    final headerTitle = _nav<Map>(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          'title'
        ]) ??
        _nav<Map>(shelf, [
          'header',
          'musicImmersiveCarouselShelfRenderer',
          'title'
        ]);
    final title = _runs(headerTitle);

    final rawContents = shelf['contents'];
    if (rawContents is! List || rawContents.isEmpty) {
      return YtSection(
          title: title, songs: [], albums: [], artists: [], playlists: []);
    }

    final type = _detectShelfType(rawContents);
    final songs = <YtSong>[];
    final albums = <YtAlbum>[];
    final artists = <YtArtist>[];
    final playlists = <YtPlaylist>[];

    for (final item in rawContents) {
      if (item is! Map) continue;
      final twoRow = item['musicTwoRowItemRenderer'];
      final responsive = item['musicResponsiveListItemRenderer'];

      switch (type) {
        case _ShelfType.song:
          if (twoRow is Map) {
            final song =
                _parseSongFromTwoRow(Map<String, dynamic>.from(twoRow));
            if (song != null && song.isValid && _songPassesFilter(song)) {
              songs.add(song);
            }
          } else if (responsive is Map) {
            final song = _parseSongFromResponsive(
                Map<String, dynamic>.from(responsive));
            if (song != null && song.isValid && _songPassesFilter(song)) {
              songs.add(song);
            }
          }
          break;
        case _ShelfType.album:
          if (twoRow is Map) {
            final album =
                _parseAlbumFromTwoRow(Map<String, dynamic>.from(twoRow));
            if (album != null && album.isValid) albums.add(album);
          }
          break;
        case _ShelfType.artist:
          if (twoRow is Map) {
            final artist =
                _parseArtistFromTwoRow(Map<String, dynamic>.from(twoRow));
            if (artist != null && artist.isValid) artists.add(artist);
          }
          break;
        case _ShelfType.playlist:
          if (twoRow is Map) {
            final playlist =
                _parsePlaylistFromTwoRow(Map<String, dynamic>.from(twoRow));
            if (playlist != null && playlist.isValid) playlists.add(playlist);
          }
          break;
      }
    }

    return YtSection(
        title: title,
        songs: songs,
        albums: albums,
        artists: artists,
        playlists: playlists);
  }

  /// Parses the `sectionListRenderer.contents` array into sections + mood chips.
  (List<YtSection>, List<YtMoodChip>) _parseSectionList(
      List<dynamic> contents) {
    final sections = <YtSection>[];
    final chips = <YtMoodChip>[];

    for (final item in contents) {
      if (item is! Map) continue;

      // ── Mood chips from chipCloudRenderer ─────────────────────────────────
      final chipCloud =
          item['chipCloudRenderer'] as Map?;
      if (chipCloud != null) {
        final chipItems = chipCloud['chips'];
        if (chipItems is List) {
          for (final chip in chipItems) {
            if (chip is! Map) continue;
            final chipRenderer = chip['chipCloudChipRenderer'];
            if (chipRenderer is! Map) continue;
            final label = _runs(chipRenderer['text']);
            // chips use browseEndpoint with a params field
            final params = _nav<String>(chipRenderer, [
                  'navigationEndpoint',
                  'browseEndpoint',
                  'params'
                ]) ??
                _nav<String>(chipRenderer,
                    ['navigationEndpoint', 'browseEndpoint', 'browseId']);
            if (label.isNotEmpty && params != null && params.isNotEmpty) {
              chips.add(YtMoodChip(label: label, params: params));
            }
          }
        }
      }

      // ── Carousel shelves ──────────────────────────────────────────────────
      final carousel = item['musicCarouselShelfRenderer'] as Map? ??
          item['musicImmersiveCarouselShelfRenderer'] as Map?;
      if (carousel != null) {
        final section = _parseShelf(Map<String, dynamic>.from(carousel));
        if (section.isNotEmpty) {
          debugPrint(
              '[YtMusicService] section "${section.title}": '
              '${section.songs.length} songs, ${section.albums.length} albums, '
              '${section.artists.length} artists, '
              '${section.playlists.length} playlists');
          sections.add(section);
        }
        continue;
      }

      // ── musicCardShelfRenderer (sometimes used for "Quick picks") ─────────
      final cardShelf = item['musicCardShelfRenderer'] as Map?;
      if (cardShelf != null) {
        final titleObj = _nav<Map>(cardShelf, ['title']);
        final shelfTitle = _runs(titleObj);
        final songs = <YtSong>[];

        // The header itself may be a song
        final headerVideoId = _nav<String>(
            cardShelf, ['title', 'runs', 0, 'navigationEndpoint',
            'watchEndpoint', 'videoId']);
        if (headerVideoId != null && headerVideoId.isNotEmpty) {
          final headerTitle = _runs(cardShelf['title']);
          final subtitleObj = cardShelf['subtitle'];
          final subtitleText = _runs(subtitleObj);
          String artist = subtitleText;
          if (subtitleText.contains(' • ')) {
            artist = subtitleText.split(' • ').last.trim();
          }
          final thumbWrapper =
              cardShelf['thumbnail'] ?? cardShelf['thumbnailRenderer'];
          final coverUrl = _thumbFromWrapper(thumbWrapper);
          final song = YtSong(
            videoId: headerVideoId,
            title: headerTitle,
            artist: artist,
            coverUrl: coverUrl,
            duration: Duration.zero,
          );
          if (song.isValid && _songPassesFilter(song)) songs.add(song);
        }

        // Additional items (usually musicResponsiveListItemRenderer)
        final contents = cardShelf['contents'];
        if (contents is List) {
          for (final r in contents) {
            if (r is! Map) continue;
            final responsive = r['musicResponsiveListItemRenderer'];
            if (responsive is Map) {
              final song = _parseSongFromResponsive(
                  Map<String, dynamic>.from(responsive));
              if (song != null && song.isValid && _songPassesFilter(song)) {
                songs.add(song);
              }
            }
            final twoRow = r['musicTwoRowItemRenderer'];
            if (twoRow is Map) {
              final song =
                  _parseSongFromTwoRow(Map<String, dynamic>.from(twoRow));
              if (song != null && song.isValid && _songPassesFilter(song)) {
                songs.add(song);
              }
            }
          }
        }

        if (songs.isNotEmpty) {
          debugPrint(
              '[YtMusicService] cardShelf "$shelfTitle": ${songs.length} songs');
          sections.add(YtSection(
              title: shelfTitle,
              songs: songs,
              albums: [],
              artists: [],
              playlists: []));
        }
        continue;
      }

      // ── gridRenderer (used on moods & genres page) ────────────────────────
      final grid = item['gridRenderer'] as Map?;
      if (grid != null) {
        final gridItems = grid['items'];
        if (gridItems is List) {
          final localChips = <YtMoodChip>[];
          for (final gridItem in gridItems) {
            if (gridItem is! Map) continue;
            final btn = gridItem['musicNavigationButtonRenderer'];
            if (btn is! Map) continue;
            final label = _runs(btn['buttonText']);
            final params = _nav<String>(
                btn, ['clickCommand', 'browseEndpoint', 'params']);
            if (label.isNotEmpty && params != null && params.isNotEmpty) {
              localChips.add(YtMoodChip(label: label, params: params));
            }
          }
          chips.addAll(localChips);
        }
        continue;
      }

      // ── musicShelfRenderer (artist pages, explore) ────────────────────────
      final shelf = item['musicShelfRenderer'] as Map?;
      if (shelf != null) {
        final shelfContents = shelf['contents'];
        if (shelfContents is List) {
          final titleObj = _nav<Map>(shelf, ['title']);
          final shelfTitle = _runs(titleObj);
          final songs = <YtSong>[];
          for (final r in shelfContents) {
            if (r is! Map) continue;
            final responsive = r['musicResponsiveListItemRenderer'];
            if (responsive is Map) {
              final song = _parseSongFromResponsive(
                  Map<String, dynamic>.from(responsive));
              if (song != null && song.isValid && _songPassesFilter(song)) {
                songs.add(song);
              }
            }
          }
          if (songs.isNotEmpty) {
            debugPrint(
                '[YtMusicService] musicShelf "$shelfTitle": '
                '${songs.length} songs');
            sections.add(YtSection(
                title: shelfTitle,
                songs: songs,
                albums: [],
                artists: [],
                playlists: []));
          }
        }
      }
    }

    debugPrint(
        '[YtMusicService] _parseSectionList: ${sections.length} sections, '
        '${chips.length} chips');
    return (sections, chips);
  }

  // ── Helper: extract sectionList contents from a browse response ────────────

  List<dynamic>? _sectionContentsFromBrowse(Map<String, dynamic> body) {
    // Path 1: singleColumnBrowseResultsRenderer → tabs[0]
    // tabs is a List<dynamic> so we must index with int, not string.
    final tabs = _nav<List>(
        body, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs']);
    if (tabs != null && tabs.isNotEmpty) {
      final tab = tabs[0]; // List, so int index
      if (tab is Map) {
        final contents = _nav<List>(tab, [
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents'
        ]);
        if (contents != null) {
          debugPrint(
              '[YtMusicService] sectionContents via tabs[0]: '
              '${contents.length} items');
          return contents;
        }
      }
    }

    // Path 2: twoColumnBrowseResultsRenderer secondary tab
    final tabs2 = _nav<List>(
        body, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs']);
    if (tabs2 != null && tabs2.isNotEmpty) {
      final tab = tabs2[0];
      if (tab is Map) {
        final contents = _nav<List>(tab, [
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents'
        ]);
        if (contents != null) {
          debugPrint(
              '[YtMusicService] sectionContents via twoColumn tabs[0]: '
              '${contents.length} items');
          return contents;
        }
      }
    }

    // Path 3: direct sectionListRenderer (some browse pages)
    final direct = _nav<List>(body, ['contents', 'sectionListRenderer', 'contents']);
    if (direct != null) {
      debugPrint(
          '[YtMusicService] sectionContents via direct sectionListRenderer: '
          '${direct.length} items');
      return direct;
    }

    debugPrint(
        '[YtMusicService] _sectionContentsFromBrowse: no known path matched. '
        'Top-level keys: ${body.keys.toList()}');
    return null;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Fetches the YouTube Music home feed.
  ///
  /// Stale-while-revalidate; listen on `revisions(kHomeFeedKey)` for the
  /// background refresh.
  Future<(List<YtSection>, List<YtMoodChip>)> getHomeFeed() => _swr(
        kHomeFeedKey,
        _fetchHomeFeed,
        encode: _encodeHomeFeed,
        decode: _decodeHomeFeed,
      );

  static Map<String, dynamic> _encodeHomeFeed(
    (List<YtSection>, List<YtMoodChip>) value,
  ) =>
      {
        'sections': YtSection.encodeList(value.$1),
        'chips': YtMoodChip.encodeList(value.$2),
      };

  static (List<YtSection>, List<YtMoodChip>) _decodeHomeFeed(
    dynamic json,
  ) {
    final map = json is Map ? json : const {};
    return (
      ytSectionListFrom(map['sections']),
      ytMoodChipListFrom(map['chips']),
    );
  }

  /// Network half of [getHomeFeed].
  Future<(List<YtSection>, List<YtMoodChip>)> _fetchHomeFeed() async {
    try {
      debugPrint('[YtMusicService] getHomeFeed: fetching FEmusic_home');
      final body = await _post('browse', {'browseId': 'FEmusic_home'});
      if (body == null) {
        debugPrint('[YtMusicService] getHomeFeed: body is null');
        return (<YtSection>[], <YtMoodChip>[]);
      }

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) {
        debugPrint('[YtMusicService] getHomeFeed: no section contents');
        return (<YtSection>[], <YtMoodChip>[]);
      }

      final result = _parseSectionList(contents);
      debugPrint(
          '[YtMusicService] getHomeFeed: ${result.$1.length} sections, '
          '${result.$2.length} chips');
      return result;
    } catch (e) {
      debugPrint('[YtMusicService] getHomeFeed error: $e');
      return (<YtSection>[], <YtMoodChip>[]);
    }
  }

  /// Fetches the home feed filtered by a mood / genre params string.
  Future<List<YtSection>> getHomeFeedForMood(String params) => _swr(
        homeMoodKey(params),
        () => _fetchHomeFeedForMood(params),
        encode: YtSection.encodeList,
        decode: ytSectionListFrom,
      );

  /// Network half of [getHomeFeedForMood].
  Future<List<YtSection>> _fetchHomeFeedForMood(String params) async {
    try {
      debugPrint(
          '[YtMusicService] getHomeFeedForMood: params=${params.substring(0, params.length.clamp(0, 30))}...');
      final body = await _post(
          'browse', {'browseId': 'FEmusic_home', 'params': params});
      if (body == null) return [];

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) return [];

      final (sections, _) = _parseSectionList(contents);
      debugPrint(
          '[YtMusicService] getHomeFeedForMood: ${sections.length} sections');
      return sections;
    } catch (e) {
      debugPrint('[YtMusicService] getHomeFeedForMood error: $e');
      return [];
    }
  }

  /// Fetches the Explore page (new releases, charts).
  Future<List<YtSection>> getExplore() => _swr(
        kExploreKey,
        _fetchExplore,
        encode: YtSection.encodeList,
        decode: ytSectionListFrom,
      );

  /// Network half of [getExplore].
  Future<List<YtSection>> _fetchExplore() async {
    try {
      debugPrint('[YtMusicService] getExplore: fetching FEmusic_explore');
      final body = await _post('browse', {'browseId': 'FEmusic_explore'});
      if (body == null) return [];

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) return [];

      final (sections, _) = _parseSectionList(contents);
      debugPrint('[YtMusicService] getExplore: ${sections.length} sections');
      return sections;
    } catch (e) {
      debugPrint('[YtMusicService] getExplore error: $e');
      return [];
    }
  }

  /// Fetches mood and genre navigation chips from FEmusic_moods_and_genres.
  Future<List<YtMoodChip>> getMoodsAndGenres() => _swr(
        kMoodsGenresKey,
        _fetchMoodsAndGenres,
        encode: YtMoodChip.encodeList,
        decode: ytMoodChipListFrom,
      );

  /// Network half of [getMoodsAndGenres].
  Future<List<YtMoodChip>> _fetchMoodsAndGenres() async {
    try {
      debugPrint(
          '[YtMusicService] getMoodsAndGenres: fetching FEmusic_moods_and_genres');
      final body =
          await _post('browse', {'browseId': 'FEmusic_moods_and_genres'});
      if (body == null) return [];

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) return [];

      final (_, chips) = _parseSectionList(contents);
      debugPrint('[YtMusicService] getMoodsAndGenres: ${chips.length} chips');
      return chips;
    } catch (e) {
      debugPrint('[YtMusicService] getMoodsAndGenres error: $e');
      return [];
    }
  }

  /// Searches YouTube Music for songs matching [query].
  ///
  /// Results are keyed by the normalised query, so revisiting a search term is
  /// instant and a re-search updates the list in place.
  Future<List<YtSong>> searchSongs(String query) {
    if (query.trim().isEmpty) return Future.value(const <YtSong>[]);
    return _swr(
      searchKey(query),
      () => _fetchSearchSongs(query),
      encode: YtSong.encodeList,
      decode: ytSongListFrom,
    );
  }

  /// Network half of [searchSongs].
  Future<List<YtSong>> _fetchSearchSongs(String query) async {
    try {
      debugPrint('[YtMusicService] searchSongs: "$query"');
      final body = await _post('search', {
        'query': query,
        'params': 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D',
      });
      if (body == null) return [];

      final tabs = _nav<List>(
          body, ['contents', 'tabbedSearchResultsRenderer', 'tabs']);
      if (tabs == null || tabs.isEmpty) return [];

      final tab = tabs[0];
      if (tab is! Map) return [];
      final sectionContents = _nav<List>(
          tab, ['tabRenderer', 'content', 'sectionListRenderer', 'contents']);
      if (sectionContents == null) return [];

      final songs = <YtSong>[];
      for (final item in sectionContents) {
        if (item is! Map) continue;
        final shelf = item['musicShelfRenderer'];
        if (shelf is! Map) continue;
        final shelfContents = shelf['contents'];
        if (shelfContents is! List) continue;
        for (final r in shelfContents) {
          if (r is! Map) continue;
          final responsive = r['musicResponsiveListItemRenderer'];
          if (responsive is Map) {
            final song = _parseSongFromResponsive(
                Map<String, dynamic>.from(responsive));
            if (song != null && song.isValid && _songPassesFilter(song)) {
              songs.add(song);
            }
          }
        }
      }

      debugPrint('[YtMusicService] searchSongs "$query": ${songs.length} songs');
      return songs;
    } catch (e) {
      debugPrint('[YtMusicService] searchSongs error: $e');
      return [];
    }
  }

  /// Returns the top songs for an artist identified by [artistBrowseId].
  Future<List<YtSong>> getArtistTopSongs(String artistBrowseId) {
    if (artistBrowseId.isEmpty) return Future.value(const <YtSong>[]);
    return _swr(
      artistSongsKey(artistBrowseId),
      () => _fetchArtistTopSongs(artistBrowseId),
      encode: YtSong.encodeList,
      decode: ytSongListFrom,
    );
  }

  /// Network half of [getArtistTopSongs].
  Future<List<YtSong>> _fetchArtistTopSongs(String artistBrowseId) async {
    try {
      debugPrint(
          '[YtMusicService] getArtistTopSongs: browseId=$artistBrowseId');
      final body = await _post('browse', {'browseId': artistBrowseId});
      if (body == null) return [];

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) return [];

      final songs = <YtSong>[];

      for (final item in contents) {
        if (item is! Map) continue;
        final shelf = item['musicShelfRenderer'];
        if (shelf is! Map) continue;

        final titleObj = _nav<Map>(shelf, ['title']);
        final titleText = _runs(titleObj).toLowerCase();
        final hasSongsTitle =
            titleText.contains('song') || titleText.isEmpty;
        final hasBottomEndpoint = shelf['bottomEndpoint'] != null;
        if (!hasSongsTitle && !hasBottomEndpoint) continue;

        final shelfContents = shelf['contents'];
        if (shelfContents is! List) continue;

        for (final r in shelfContents) {
          if (r is! Map) continue;
          final responsive = r['musicResponsiveListItemRenderer'];
          if (responsive is Map) {
            final song = _parseSongFromResponsive(
                Map<String, dynamic>.from(responsive));
            if (song != null && song.isValid && _songPassesFilter(song)) {
              songs.add(song);
            }
          }
        }
        if (songs.isNotEmpty) break;
      }

      debugPrint(
          '[YtMusicService] getArtistTopSongs $artistBrowseId: '
          '${songs.length} songs');
      return songs;
    } catch (e) {
      debugPrint('[YtMusicService] getArtistTopSongs error: $e');
      return [];
    }
  }

  /// Returns artists related to [artistBrowseId].
  ///
  /// An empty result is cached on purpose (the network said "no related
  /// artists", not "the call failed"), so this feed stops retrying on every
  /// visit.
  Future<List<YtArtist>> getRelatedArtists(String artistBrowseId) {
    if (artistBrowseId.isEmpty) return Future.value(const <YtArtist>[]);
    return _swr(
      relatedArtistsKey(artistBrowseId),
      () => _fetchRelatedArtists(artistBrowseId),
      encode: YtArtist.encodeList,
      decode: ytArtistListFrom,
    );
  }

  /// Network half of [getRelatedArtists].
  Future<List<YtArtist>> _fetchRelatedArtists(String artistBrowseId) async {
    try {
      debugPrint(
          '[YtMusicService] getRelatedArtists: browseId=$artistBrowseId');
      final body = await _post('browse', {'browseId': artistBrowseId});
      if (body == null) return [];

      final contents = _sectionContentsFromBrowse(body);
      if (contents == null) return [];

      const relatedKeywords = [
        'fans might also like',
        'related artists',
        'similar'
      ];

      for (final item in contents) {
        if (item is! Map) continue;
        final carousel = item['musicCarouselShelfRenderer'];
        if (carousel is! Map) continue;

        final headerTitle = _nav<Map>(carousel,
            ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']);
        final title = _runs(headerTitle).toLowerCase();
        final isRelated = relatedKeywords.any((kw) => title.contains(kw));
        if (!isRelated) continue;

        final shelfContents = carousel['contents'];
        if (shelfContents is! List) continue;

        final artists = <YtArtist>[];
        for (final r in shelfContents) {
          if (r is! Map) continue;
          final twoRow = r['musicTwoRowItemRenderer'];
          if (twoRow is Map) {
            final artist =
                _parseArtistFromTwoRow(Map<String, dynamic>.from(twoRow));
            if (artist != null && artist.isValid) artists.add(artist);
          }
        }
        if (artists.isNotEmpty) {
          debugPrint(
              '[YtMusicService] getRelatedArtists: ${artists.length} artists');
          return artists;
        }
      }

      return [];
    } catch (e) {
      debugPrint('[YtMusicService] getRelatedArtists error: $e');
      return [];
    }
  }

  /// Returns the "Up Next" queue for a given [videoId].
  Future<List<YtSong>> getUpNext(String videoId) {
    if (videoId.isEmpty) return Future.value(const <YtSong>[]);
    return _swr(
      upNextKey(videoId),
      () => _fetchUpNext(videoId),
      encode: YtSong.encodeList,
      decode: ytSongListFrom,
    );
  }

  /// Network half of [getUpNext].
  Future<List<YtSong>> _fetchUpNext(String videoId) async {

    try {
      debugPrint('[YtMusicService] getUpNext: videoId=$videoId');
      final body = await _post('next', {
        'videoId': videoId,
        'isAudioOnly': true,
      });
      if (body == null) return [];

      final tabs = _nav<List>(body, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer',
        'tabs',
      ]);
      if (tabs == null) return [];

      List<dynamic>? queueContents;
      for (final tab in tabs) {
        if (tab is! Map) continue;
        final tabRenderer = tab['tabRenderer'];
        if (tabRenderer is! Map) continue;
        final tabTitle = _nav<String>(tabRenderer, ['title']) ?? '';
        if (tabTitle.toLowerCase().contains('up next') ||
            tabTitle.toLowerCase().contains('queue')) {
          queueContents = _nav<List>(tabRenderer, [
            'content',
            'musicQueueRenderer',
            'content',
            'playlistPanelRenderer',
            'contents',
          ]);
          break;
        }
      }

      if (queueContents == null && tabs.isNotEmpty) {
        final firstTab = tabs[0];
        if (firstTab is Map) {
          final tabRenderer = firstTab['tabRenderer'];
          if (tabRenderer is Map) {
            queueContents = _nav<List>(tabRenderer, [
              'content',
              'musicQueueRenderer',
              'content',
              'playlistPanelRenderer',
              'contents',
            ]);
          }
        }
      }

      if (queueContents == null) return [];

      final songs = <YtSong>[];
      for (final item in queueContents) {
        if (item is! Map) continue;
        final panelVideo = item['playlistPanelVideoRenderer'];
        if (panelVideo is! Map) continue;

        final vid = _nav<String>(panelVideo, ['videoId']);
        if (vid == null || vid.isEmpty || vid == videoId) continue;

        final titleObj = panelVideo['title'];
        final title = _runs(titleObj);
        if (title.isEmpty) continue;

        final shortByline = panelVideo['shortBylineText'];
        final artist = _runs(shortByline);

        final thumbWrapper = panelVideo['thumbnail'];
        final rawCoverUrl = _thumbFromWrapper(thumbWrapper);
        final coverUrl = ThumbnailUrl.normalize(rawCoverUrl, videoId: vid);

        final durationText =
            _nav<String>(panelVideo, ['lengthText', 'runs', 0, 'text']) ??
                _runs(panelVideo['lengthText']);
        final duration = _parseDuration(durationText);

        final song = YtSong(
          videoId: vid,
          title: title,
          artist: artist,
          coverUrl: coverUrl,
          duration: duration,
        );

        if (song.isValid && _songPassesFilter(song)) {
          songs.add(song);
        }
      }

      debugPrint('[YtMusicService] getUpNext $videoId: ${songs.length} songs');
      return songs;
    } catch (e) {
      debugPrint('[YtMusicService] getUpNext error: $e');
      return [];
    }
  }

  /// Returns a personalised "Albums for you" list by merging three sources:
  /// 1. [homeAlbums] — album shelves already parsed from the home feed (free).
  /// 2. Albums/Singles from top artist pages ([topArtistBrowseIds]).
  /// 3. Album shelves from getExplore() (cached — usually instant).
  /// Results are deduped and capped at 20. Cached 30 min.
  ///
  /// This feed is derived from caller-supplied seeds, so its cache key does not
  /// distinguish between different artist sets — the same entry is reused for
  /// whatever seeds arrive first. An empty result is deliberately *not*
  /// cached, so a failed seed pass does not blank the shelf until restart.
  Future<List<YtAlbum>> getAlbumsForYou({
    List<String> topArtistBrowseIds = const [],
    List<YtAlbum> homeAlbums = const [],
  }) {
    return _swr(
      kAlbumsForYouKey,
      () => _fetchAlbumsForYou(topArtistBrowseIds, homeAlbums),
      encode: YtAlbum.encodeList,
      decode: ytAlbumListFrom,
      cacheEmpty: false,
    );
  }

  /// Network half of [getAlbumsForYou].
  Future<List<YtAlbum>> _fetchAlbumsForYou(
    List<String> topArtistBrowseIds,
    List<YtAlbum> homeAlbums,
  ) async {

    final seen = <String>{}; // browseId dedup
    final seenTitleArtist = <String>{}; // title+artist dedup
    final albums = <YtAlbum>[];

    void addAlbum(YtAlbum a) {
      if (!a.isValid) return;
      if (!seen.add(a.browseId)) return;
      final key =
          '${a.title.toLowerCase().trim()}|${a.artist.toLowerCase().trim()}';
      if (!seenTitleArtist.add(key)) return;
      albums.add(a);
    }

    // ── 1. Home feed albums (passed in — already fetched, no extra HTTP) ──────
    debugPrint('[YtMusicService] getAlbumsForYou: '
        '${homeAlbums.length} home albums seeded');
    for (final a in homeAlbums) { addAlbum(a); }

    // ── 2. Top artist pages ───────────────────────────────────────────────────
    if (topArtistBrowseIds.isNotEmpty && albums.length < 20) {
      debugPrint('[YtMusicService] getAlbumsForYou: '
          '${topArtistBrowseIds.length} artist pages');
      for (var i = 0;
          i < topArtistBrowseIds.length && albums.length < 20;
          i += 4) {
        final batch = topArtistBrowseIds
            .sublist(i, (i + 4).clamp(0, topArtistBrowseIds.length));
        final futures = batch.map((artistId) async {
          try {
            final body = await _post('browse', {'browseId': artistId});
            if (body == null) return <YtAlbum>[];
            final contents = _sectionContentsFromBrowse(body);
            if (contents == null) return <YtAlbum>[];
            final result = <YtAlbum>[];
            for (final item in contents) {
              if (item is! Map) continue;
              final carousel = item['musicCarouselShelfRenderer'] as Map?;
              if (carousel == null) continue;
              final headerTitle = _nav<Map>(carousel, [
                'header',
                'musicCarouselShelfBasicHeaderRenderer',
                'title'
              ]);
              final shelfTitle = _runs(headerTitle).toLowerCase();
              if (!shelfTitle.contains('album') &&
                  !shelfTitle.contains('single') &&
                  !shelfTitle.contains('release')) { continue; }
              final shelfContents = carousel['contents'];
              if (shelfContents is! List) continue;
              for (final r in shelfContents) {
                if (r is! Map) continue;
                final twoRow = r['musicTwoRowItemRenderer'];
                if (twoRow is! Map) continue;
                final album = _parseAlbumFromTwoRow(
                    Map<String, dynamic>.from(twoRow));
                if (album != null) result.add(album);
              }
            }
            return result;
          } catch (e) {
            debugPrint('[YtMusicService] artist $artistId albums error: $e');
            return <YtAlbum>[];
          }
        });
        for (final list in await Future.wait(futures)) {
          for (final a in list) { addAlbum(a); }
        }
      }
      debugPrint(
          '[YtMusicService] getAlbumsForYou after artists: ${albums.length}');
    }

    // ── 3. Explore (cached after getExplore() already ran) ───────────────────
    if (albums.length < 20) {
      try {
        final exploreSections = await getExplore();
        debugPrint('[YtMusicService] getAlbumsForYou explore: '
            '${exploreSections.length} sections');
        for (final section in exploreSections) {
          for (final a in section.albums) { addAlbum(a); }
          for (final p in section.playlists) {
            addAlbum(YtAlbum(
              browseId: p.browseId,
              title: p.title,
              artist: p.subtitle,
              coverUrl: p.coverUrl,
            ));
          }
        }
        debugPrint(
            '[YtMusicService] getAlbumsForYou after explore: ${albums.length}');
      } catch (e) {
        debugPrint('[YtMusicService] getAlbumsForYou explore error: $e');
      }
    }

    final result = albums.take(20).toList();
    debugPrint('[YtMusicService] getAlbumsForYou FINAL: ${result.length}');
    return result;
  }

  /// Fetches an album's metadata and track list by [browseId].
  Future<AlbumTracksData> getAlbumTracks(String browseId) => _swr(
        albumTracksKey(browseId),
        () => _fetchAlbumTracks(browseId),
        encode: _encodeAlbumTracks,
        decode: _decodeAlbumTracks,
        cacheEmpty: false,
      );

  static Map<String, dynamic> _encodeAlbumTracks(AlbumTracksData data) => {
        'title': data.title,
        'artist': data.artist,
        'coverUrl': data.coverUrl,
        'year': data.year,
        'tracks': YtSong.encodeList(data.tracks),
      };

  static AlbumTracksData _decodeAlbumTracks(dynamic json) {
    final map = json is Map ? json : const {};
    String read(String key) => map[key] is String ? map[key] as String : '';
    return AlbumTracksData(
      title: read('title'),
      artist: read('artist'),
      coverUrl: read('coverUrl'),
      year: read('year'),
      tracks: ytSongListFrom(map['tracks']),
    );
  }

  /// Network half of [getAlbumTracks].
  Future<AlbumTracksData> _fetchAlbumTracks(String browseId) async {

    final body = await _post('browse', {'browseId': browseId});
    if (body == null) throw Exception('No response for $browseId');

    // ── Header metadata ────────────────────────────────────────────────────
    String title = '';
    String artist = '';
    String coverUrl = '';
    String year = '';

    final header = _nav<Map>(body, ['header', 'musicImmersiveHeaderRenderer']) ??
        _nav<Map>(body, ['header', 'musicDetailHeaderRenderer']);
    if (header != null) {
      title = _runs(header['title']);
      artist = _runs(header['subtitle']);
      final subParts = artist.split(' • ');
      for (final part in subParts) {
        final y = int.tryParse(part.trim());
        if (y != null && y > 1900 && y < 2200) {
          year = part.trim();
          break;
        }
      }
      final thumbList = _nav<List>(header, [
            'thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'
          ]) ??
          _nav<List>(header, ['thumbnail', 'thumbnails']) ??
          _nav<List>(header, [
            'thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'
          ]);
      if (thumbList != null) {
        coverUrl = _thumb(thumbList);
      }
    }

    // ── Track list ─────────────────────────────────────────────────────────
    final contents = _sectionContentsFromBrowse(body);
    final tracks = <YtSong>[];

    if (contents != null) {
      for (final item in contents) {
        if (item is! Map) continue;
        final shelf = item['musicShelfRenderer'] as Map?;
        if (shelf == null) continue;
        final shelfContents = shelf['contents'];
        if (shelfContents is! List) continue;
        for (final r in shelfContents) {
          if (r is! Map) continue;
          final responsive = r['musicResponsiveListItemRenderer'];
          if (responsive is! Map) continue;
          final song = _parseSongFromResponsive(
              Map<String, dynamic>.from(responsive));
          if (song != null && song.isValid) {
            final cover = song.coverUrl.isNotEmpty ? song.coverUrl : coverUrl;
            tracks.add(YtSong(
              videoId: song.videoId,
              title: song.title,
              artist: song.artist.isNotEmpty ? song.artist : artist,
              album: title,
              coverUrl: cover,
              duration: song.duration,
            ));
          }
        }
        if (tracks.isNotEmpty) break;
      }
    }

    final result = AlbumTracksData(
      title: title,
      artist: artist,
      coverUrl: coverUrl,
      year: year,
      tracks: tracks,
    );

    debugPrint('[YtMusicService] getAlbumTracks $browseId: '
        '"$title" by "$artist" — ${tracks.length} tracks');
    return result;
  }

  /// Drops every cached feed, in memory and on disk, and re-fetches the
  /// visitor id.
  ///
  /// This is the pull-to-refresh / retry escape hatch: it must reach the disk
  /// tier too, otherwise a "refresh" would be handed the very rows it is meant
  /// to replace.
  void clearCache() {
    _cache.clear();
    _served.clear();
    _revalidating.clear();
    for (final controller in _revisions.values) {
      if (!controller.isClosed) controller.close();
    }
    _revisions.clear();
    unawaited(YtMusicFeedCache.instance.clear());
    _visitorId = null;
    _visitorIdFetchStarted = false;
  }

  /// Releases the per-key revision channels. Called when the app shuts down.
  void dispose() {
    clearCache();
  }
}

// ---------------------------------------------------------------------------
// Internal enum — shelf content type
// ---------------------------------------------------------------------------

enum _ShelfType { song, album, artist, playlist }

// ---------------------------------------------------------------------------
// Album data holder — returned by getAlbumTracks
// ---------------------------------------------------------------------------

class AlbumTracksData {
  final String title;
  final String artist;
  final String coverUrl;
  final String year;
  final List<YtSong> tracks;

  const AlbumTracksData({
    required this.title,
    required this.artist,
    required this.coverUrl,
    required this.year,
    required this.tracks,
  });
}
