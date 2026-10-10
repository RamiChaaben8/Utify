// ============================================================
// services/youtube_service.dart
//
// Two-level stream URL cache:
//   L1 — in-memory Map  (instant, lost on restart)
//   L2 — Hive box       (fast disk read, survives restarts)
//
// Resolution order on getAudioStreamUrl(id):
//   1. L1 hit  → return immediately (0 ms)
//   2. L2 hit  → populate L1, return (< 1 ms)
//   3. Miss    → fetch a supported MP4 stream, write to both caches
//
// This means songs the user played before will start with zero manifest
// round-trip, exactly like YT Music's behaviour.
//
// Safety margin
// ─────────────────────────────────────────────────────────────
//   Entries are stored with an explicit absolute `expiry`, not just a
//   fetch timestamp, and are only handed out while more than
//   [_kMinRemaining] of life is left. Google kills signed stream URLs
//   without warning, so a URL that is about to die must never start a
//   load we cannot finish. Rows written before the `expiry` field
//   existed are still read (their `ts` is converted on the fly), so
//   upgrading never discards a warm cache.
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';

const _kTtl = Duration(hours: 5);

/// Minimum remaining validity before a cached URL may be served.
const _kMinRemaining = Duration(minutes: 10);

const _kHiveBox = 'stream_url_cache';
const _kStreamCachePrefix = 'stream_v4_';

class _CachedUrl {
  final String url;

  /// Absolute moment this URL stops being usable.
  final DateTime expiry;

  const _CachedUrl(this.url, this.expiry);

  bool get isExpired => !DateTime.now().isBefore(expiry);

  /// True when there is enough life left to safely start a load.
  bool get isUsable => expiry.difference(DateTime.now()) > _kMinRemaining;
}

class YoutubeService {
  final YoutubeExplode _yt = YoutubeExplode();

  // L1 — in-memory
  final Map<String, _CachedUrl> _mem = {};

  // In-flight deduplication
  final Map<String, Future<String>> _inflight = {};
  final Set<String> _queuedPrefetch = {};
  final List<String> _prefetchQueue = [];
  int _activePrefetches = 0;

  YoutubeExplode get yt => _yt;

  // ── Hive helpers ─────────────────────────────────────────────────────────

  Box get _hive => Hive.box(_kHiveBox);

  _CachedUrl? _readHive(String id) {
    try {
      final map = _hive.get(id);
      if (map is! Map) return null;
      final url = map['url'];
      if (url is! String || url.isEmpty) return null;

      final expiry = map['expiry'];
      if (expiry is int) {
        return _CachedUrl(url, DateTime.fromMillisecondsSinceEpoch(expiry));
      }
      // Row written before the `expiry` field existed: derive it from the
      // fetch timestamp so an upgrade keeps every warm entry usable.
      final ts = map['ts'];
      if (ts is int) {
        return _CachedUrl(
          url,
          DateTime.fromMillisecondsSinceEpoch(ts).add(_kTtl),
        );
      }
    } catch (_) {
      // A malformed row must never break resolution — treat it as a miss.
    }
    return null;
  }

  Future<void> _writeHive(String id, String url) async {
    try {
      await _hive.put(id, {
        'url': url,
        'expiry': DateTime.now().add(_kTtl).millisecondsSinceEpoch,
      });
    } catch (e) {
      // A cache write failure must never fail playback.
      debugPrint('[YoutubeService] stream URL cache write failed: $e');
    }
  }

  /// Drops every cached URL that can no longer be served, in both tiers.
  ///
  /// Called once at startup so a long-dormant install does not carry a box
  /// full of dead rows. Returns the number of rows removed.
  Future<int> pruneExpired() async {
    var removed = 0;
    try {
      if (Hive.isBoxOpen(_kHiveBox)) {
        final box = Hive.box(_kHiveBox);
        final dead = <String>[];
        for (final key in box.keys) {
          if (key is! String || !key.startsWith(_kStreamCachePrefix)) continue;
          final entry = _readHive(key);
          if (entry == null || !entry.isUsable) dead.add(key);
        }
        if (dead.isNotEmpty) {
          await box.deleteAll(dead);
          removed += dead.length;
        }
      }
    } catch (e) {
      debugPrint('[YoutubeService] stream URL prune failed: $e');
    }
    try {
      _mem.removeWhere((_, value) => !value.isUsable);
      _videoMem.removeWhere((_, value) => !value.isUsable);
    } catch (_) {}
    if (removed > 0) {
      debugPrint('[YoutubeService] pruned $removed expired stream URL(s)');
    }
    return removed;
  }

  // ── Search ───────────────────────────────────────────────────────────────

  Future<List<Song>> search(String query, {int maxResults = 20}) async {
    try {
      final results = await _yt.search.search(query);
      return results.take(maxResults).map(_videoToSong).toList();
    } on VideoUnavailableException catch (e) {
      throw YoutubeServiceException('Video unavailable: ${e.message}');
    } catch (e) {
      throw YoutubeServiceException('Search failed: $e');
    }
  }

  /// Fetch a section of songs by a curated query string.
  /// Used for home feed sections (trending, new releases, mood, etc.)
  Future<List<Song>> searchSection(String query, {int maxResults = 10}) async {
    try {
      final results = await _yt.search.search(query);
      return results.take(maxResults).map(_videoToSong).toList();
    } catch (_) {
      return [];
    }
  }

  // ── URL resolution ────────────────────────────────────────────────────────

  Future<String> getAudioStreamUrl(String videoId) async {
    // L1 — memory
    final mem = _mem[videoId];
    if (mem != null && mem.isUsable) return mem.url;
    if (mem != null) _mem.remove(videoId);

    // L2 — Hive (fast disk read, survives restarts)
    // Use a versioned key so URLs cached before the compatibility fallback
    // existed are not reused indefinitely.
    final hive = _readHive('$_kStreamCachePrefix$videoId');
    if (hive != null && hive.isUsable) {
      _mem[videoId] = hive; // promote to L1
      return hive.url;
    }

    // Already fetching — reuse the same Future
    if (_inflight.containsKey(videoId)) return _inflight[videoId]!;

    final future = _fetchAndCache(videoId);
    _inflight[videoId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(videoId);
    }

  }

  /// Returns distinct stream URLs in playback order. Keeping alternatives
  /// lets the player move to another container when one format stalls or the
  /// device decoder rejects it.
  Future<List<String>> getAudioStreamCandidates(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      final muxedMp4 = manifest.muxed
          .where((stream) => stream.container.name == 'mp4')
          .toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      final audioMp4 = manifest.audioOnly
          .where((stream) => stream.container.name == 'mp4')
          .toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      final otherMuxed = manifest.muxed
          .where((stream) => stream.container.name != 'mp4')
          .toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      final otherAudio = manifest.audioOnly
          .where((stream) => stream.container.name != 'mp4')
          .toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      final hls = manifest.hls.toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));

      final ordered = <StreamInfo>[];
      for (var index = 0;
          index < [muxedMp4.length, audioMp4.length, hls.length, otherMuxed.length, otherAudio.length]
              .reduce((a, b) => a > b ? a : b);
          index++) {
        if (index < muxedMp4.length) ordered.add(muxedMp4[index]);
        if (index < audioMp4.length) ordered.add(audioMp4[index]);
        if (index < hls.length) ordered.add(hls[index]);
        if (index < otherMuxed.length) ordered.add(otherMuxed[index]);
        if (index < otherAudio.length) ordered.add(otherAudio[index]);
      }

      final seen = <String>{};
      return ordered.map((stream) => stream.url.toString())
          .where((url) => seen.add(url))
          .toList();
    } on VideoRequiresPurchaseException {
      throw YoutubeServiceException('This video requires a purchase.');
    } on VideoUnplayableException catch (e) {
      throw YoutubeServiceException('Video unplayable: ${e.message}');
    } catch (e) {
      if (e is YoutubeServiceException) rethrow;
      throw YoutubeServiceException('Failed to get stream candidates: $e');
    }
  }

  /// Resolves an audio-only stream URL.
  Future<String> getAudioOnlyStreamUrl(String videoId) async {
    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    var streams =
        manifest.audioOnly.where((s) => s.container.name == 'mp4').toList();
    if (streams.isEmpty) streams = manifest.audioOnly.toList();
    if (streams.isEmpty) {
      throw YoutubeServiceException('No audio-only stream found for $videoId');
    }
    streams.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    return streams.first.url.toString();
  }

  Future<String> _fetchAndCache(String videoId) async {
    try {
      final candidates = await getAudioStreamCandidates(videoId);
      if (candidates.isEmpty) {
        throw YoutubeServiceException('No audio streams found for $videoId');
      }

      final url = candidates.first;

      // Write to both caches
      final cached = _CachedUrl(url, DateTime.now().add(_kTtl));
      _mem[videoId] = cached;
      unawaited(_writeHive('$_kStreamCachePrefix$videoId', url));

      return url;
    } on VideoRequiresPurchaseException {
      throw YoutubeServiceException('This video requires a purchase.');
    } on VideoUnplayableException catch (e) {
      throw YoutubeServiceException('Video unplayable: ${e.message}');
    } catch (e) {
      if (e is YoutubeServiceException) rethrow;
      throw YoutubeServiceException('Failed to get stream URL: $e');
    }
  }

  // ── Video stream URL ─────────────────────────────────────────────────────
  // Returns a muxed (video+audio) MP4 stream URL suitable for video_player.
  // Uses the highest quality muxed stream available (up to 720p typically).
  // Note: separate high-res video streams (>720p) are not muxed on YouTube.

  final Map<String, _CachedUrl> _videoMem = {};

  Future<String> getVideoStreamUrl(String videoId) async {
    final mem = _videoMem[videoId];
    if (mem != null && mem.isUsable) return mem.url;
    if (mem != null) _videoMem.remove(videoId);

    if (_inflight.containsKey('v_$videoId')) return _inflight['v_$videoId']!;

    final future = _fetchVideoUrl(videoId);
    _inflight['v_$videoId'] = future;
    try {
      return await future;
    } finally {
      _inflight.remove('v_$videoId');
    }
  }

  Future<String> _fetchVideoUrl(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);

      // Prefer highest bitrate muxed MP4 (these include both video and audio)
      var streams = manifest.muxed
          .where((s) => s.container.name == 'mp4')
          .toList();
      if (streams.isEmpty) streams = manifest.muxed.toList();
      if (streams.isEmpty) {
        throw YoutubeServiceException('No video streams found for $videoId');
      }

      // Sort descending — best quality first
      streams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final url = streams.first.url.toString();

      _videoMem[videoId] = _CachedUrl(url, DateTime.now().add(_kTtl));
      return url;
    } on VideoRequiresPurchaseException {
      throw YoutubeServiceException('This video requires a purchase.');
    } on VideoUnplayableException catch (e) {
      throw YoutubeServiceException('Video unplayable: ${e.message}');
    } catch (e) {
      if (e is YoutubeServiceException) rethrow;
      throw YoutubeServiceException('Failed to get video stream URL: $e');
    }
  }

  // ── Prefetch ─────────────────────────────────────────────────────────────

  static const int _kMaxPrefetchQueue = 6;

  void prefetchUrl(String videoId) {
    final mem = _mem[videoId];
    if (mem != null && mem.isUsable) return;
    final hive = _readHive('$_kStreamCachePrefix$videoId');
    if (hive != null && hive.isUsable) {
      _mem[videoId] = hive;
      return; // already cached — no network needed
    }
    if (_inflight.containsKey(videoId) || !_queuedPrefetch.add(videoId)) return;

    if (_prefetchQueue.length >= _kMaxPrefetchQueue) {
      final dropped = _prefetchQueue.removeLast();
      _queuedPrefetch.remove(dropped);
    }

    _prefetchQueue.add(videoId);
    _drainPrefetchQueue();
  }

  void clearPrefetchQueue() {
    _prefetchQueue.clear();
    _queuedPrefetch.clear();
  }

  void _drainPrefetchQueue() {
    while (_activePrefetches < 3 && _prefetchQueue.isNotEmpty) {
      final id = _prefetchQueue.removeAt(0);
      _queuedPrefetch.remove(id);
      if (_inflight.containsKey(id)) continue;
      _activePrefetches++;
      getAudioStreamUrl(id).catchError((_) => '').whenComplete(() {
        _activePrefetches--;
        _drainPrefetchQueue();
      });
    }
  }

  /// Seed the memory cache directly from a [Song]'s stored [Song.streamUrl]
  /// field (written by AudioPlayerService after each play).
  /// This is zero-cost — no Hive read, no network.
  void seedFromSong(Song song) {
    final cachedMime = song.streamUrl == null
        ? null
        : Uri.tryParse(song.streamUrl!)?.queryParameters['mime'];
    // Old song records may hold audio-only streams that previously stalled on
    // some devices. Prefer a compatible muxed stream for the first attempt.
    if (cachedMime?.startsWith('audio/') ?? false) return;
    final fetchedAt = song.streamUrlFetchedAt;
    if (song.streamUrl == null || fetchedAt == null) return;
    // Apply the same 10-minute safety margin as every other read path so a
    // per-Song URL is never served in its final minutes.
    final expiry = fetchedAt.add(_kTtl);
    if (expiry.difference(DateTime.now()) <= _kMinRemaining) return;
    _mem[song.id] ??= _CachedUrl(song.streamUrl!, expiry);
  }

  void rememberAudioStreamUrl(String videoId, String url) {
    _mem[videoId] = _CachedUrl(url, DateTime.now().add(_kTtl));
    unawaited(_writeHive('$_kStreamCachePrefix$videoId', url));
  }

  /// Drops any cached URL for [videoId] in both tiers.
  ///
  /// Used when a stream turns out to be dead (expired signature, refused
  /// container) so the next attempt is forced to re-resolve from the manifest
  /// instead of replaying a known-bad URL.
  void forgetStreamUrl(String videoId) {
    _mem.remove(videoId);
    try {
      final key = '$_kStreamCachePrefix$videoId';
      if (Hive.isBoxOpen(_kHiveBox) && Hive.box(_kHiveBox).containsKey(key)) {
        Hive.box(_kHiveBox).delete(key).catchError((_) {});
      }
    } catch (_) {
      // Cache eviction is best-effort.
    }
  }

  void prefetchBatch(List<String> videoIds, {int maxConcurrent = 3}) {
    final needed = videoIds.where((id) {
      final mem = _mem[id];
      if (mem != null && mem.isUsable) return false;
      final hive = _readHive('$_kStreamCachePrefix$id');
      if (hive != null && hive.isUsable) {
        _mem[id] = hive; // warm L1 from L2 for free
        return false;
      }
      return !_inflight.containsKey(id);
    }).take(maxConcurrent).toList();

    for (final id in needed) {
      prefetchUrl(id);
    }
  }

  // ── Video info ────────────────────────────────────────────────────────────

  Future<Song> getVideoInfo(String videoId) async {
    try {
      return _videoToSong(await _yt.videos.get(videoId));
    } catch (e) {
      throw YoutubeServiceException('Failed to fetch video info: $e');
    }
  }

  Song _videoToSong(Video video) {
    final thumb = 'https://i.ytimg.com/vi/${video.id.value}/mqdefault.jpg';
    return Song(
      id: video.id.value,
      title: video.title,
      channelName: video.author,
      thumbnailUrl: thumb,
      duration: video.duration ?? Duration.zero,
    );
  }

  // ── Captions / Lyrics ─────────────────────────────────────────────────────

  /// Returns all available caption tracks for a video, deduplicated by
  /// language code (one entry per language, preferring non-auto-generated).
  Future<List<CaptionTrackInfo>> getAvailableCaptionTracks(String videoId) async {
    try {
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);

      // Group by language code, prefer manual over auto-generated
      final Map<String, CaptionTrackInfo> seen = {};
      for (final t in manifest.tracks) {
        final code = t.language.code;
        final label = t.isAutoGenerated
            ? '${t.language.name} (auto-generated)'
            : t.language.name;
        final info = CaptionTrackInfo(
          code: code,
          label: label,
          isAutoGenerated: t.isAutoGenerated,
        );
        // Only add if not seen yet, OR replace an auto-generated with a manual one
        if (!seen.containsKey(code) ||
            (seen[code]!.isAutoGenerated && !t.isAutoGenerated)) {
          seen[code] = info;
        }
      }

      return seen.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// Returns a list of caption lines for the given video.
  /// Tries English first, then any available track.
  /// Returns an empty list if no captions are available.
  Future<List<LyricLine>> getLyrics(String videoId) async {
    try {
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);
      if (manifest.tracks.isEmpty) return [];

      // Prefer English, fall back to first available
      final trackInfo = manifest.tracks.firstWhere(
        (t) => t.language.code.startsWith('en'),
        orElse: () => manifest.tracks.first,
      );

      return _fetchTrack(trackInfo);
    } catch (_) {
      return [];
    }
  }

  /// Fetch lyrics for a specific track by language code.
  /// Prefers manual captions over auto-generated when both exist.
  Future<List<LyricLine>> getLyricsForTrack(
      String videoId, String languageCode) async {
    try {
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);
      if (manifest.tracks.isEmpty) return [];

      final matches = manifest.tracks
          .where((t) => t.language.code == languageCode)
          .toList();
      if (matches.isEmpty) return [];

      // Prefer manual over auto-generated
      final trackInfo = matches.firstWhere(
        (t) => !t.isAutoGenerated,
        orElse: () => matches.first,
      );

      return _fetchTrack(trackInfo);
    } catch (_) {
      return [];
    }
  }

  Future<List<LyricLine>> _fetchTrack(dynamic trackInfo) async {
    final track = await _yt.videos.closedCaptions.get(trackInfo);
    return track.captions.map((c) {
      // Build per-word list from caption parts when available
      final words = c.parts.map((p) => LyricWord(
        text: p.text.trim(),
        // part.offset is relative to the caption's own offset
        start: c.offset + p.offset,
      )).where((w) => w.text.isNotEmpty).toList();

      return LyricLine(
        text: c.text.trim(),
        start: c.offset,
        end: c.offset + c.duration,
        words: words,
      );
    }).where((l) => l.text.isNotEmpty).toList();
  }

  void dispose() => _yt.close();
}

class LyricLine {
  final String text;
  final Duration start;
  final Duration end;
  // Per-word timing (empty when not available — manual captions rarely have this)
  final List<LyricWord> words;

  const LyricLine({
    required this.text,
    required this.start,
    required this.end,
    this.words = const [],
  });

  bool get hasWordTiming => words.isNotEmpty;
}

class LyricWord {
  final String text;
  // Absolute start time (caption.offset + part.offset)
  final Duration start;

  const LyricWord({required this.text, required this.start});
}

class CaptionTrackInfo {
  final String code;
  final String label;
  final bool isAutoGenerated;
  const CaptionTrackInfo({
    required this.code,
    required this.label,
    required this.isAutoGenerated,
  });
}

class YoutubeServiceException implements Exception {
  final String message;
  const YoutubeServiceException(this.message);
  @override
  String toString() => 'YoutubeServiceException: $message';
}
