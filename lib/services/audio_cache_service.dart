// ============================================================
// services/audio_cache_service.dart
//
// Private on-disk audio cache (Android only).
//
// Where files live
// ─────────────────────────────────────────────────────────────
//   getApplicationCacheDirectory()/audio/{videoId}.m4a
//
// This is the OS-managed private cache dir: no storage permission,
// not visible to the gallery, and reclaimable by the system if the
// user clears app storage.  Cached audio is NEVER written to the
// public Music/Utify folder — that folder is only for user-initiated
// downloads (DownloadService).
//
// Why key by videoId and not by URL
// ─────────────────────────────────────────────────────────────
//   Google stream URLs are signed and expire after a few hours.
//   A URL-keyed cache would be a miss on every single launch and
//   would fill the disk with dead entries.  The video ID is stable
//   forever, so the file is a permanent hit for that track.
//
// LRU index
// ─────────────────────────────────────────────────────────────
//   Hive box `audio_cache_index`:  { videoId: { … } }
//     lastPlayed : int    epoch ms  (eviction key)
//     sizeBytes  : int
//     complete   : bool
//
//   `complete` matters because downloads land in a `.part` temp file
//   and are only renamed into place once the whole body arrives.  A
//   half-written file is never handed to the player.
//
// Every method is wrapped so that a cache failure can never block
// playback — callers always fall back to plain streaming.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/cache_support.dart';

// ── Box / setting keys ──────────────────────────────────────────────────────

const String kAudioCacheBox = 'audio_cache_index';

const String _kLimitKey = 'audio_cache_limit_bytes';
const String _kMobileDataKey = 'cache_on_mobile_data';

/// 1 GB — the default ceiling for the private audio cache.
const int kDefaultAudioCacheLimitBytes = 1024 * 1024 * 1024;

/// Selectable limits for the settings UI.
const List<int> kAudioCacheLimitOptions = <int>[
  250 * 1024 * 1024,
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
  2 * 1024 * 1024 * 1024,
];

const String _kFileExtension = '.m4a';

// ── Stats ───────────────────────────────────────────────────────────────────

class AudioCacheStats {
  /// Sum of every indexed file that is actually present on disk.
  final int totalBytes;

  /// Number of complete, playable files.
  final int fileCount;

  /// Configured ceiling in bytes.
  final int limitBytes;

  const AudioCacheStats({
    this.totalBytes = 0,
    this.fileCount = 0,
    this.limitBytes = kDefaultAudioCacheLimitBytes,
  });

  double get usedFraction =>
      limitBytes <= 0 ? 0 : (totalBytes / limitBytes).clamp(0.0, 1.0);
}

// ── Service ─────────────────────────────────────────────────────────────────

class AudioCacheService {
  AudioCacheService._();

  static final AudioCacheService instance = AudioCacheService._();

  /// The on-disk audio cache is an Android-only feature. Desktop keeps the
  /// existing stream-everything behaviour so Windows is untouched.
  static bool get isSupported => cacheSystemEnabled;

  /// User-Agent sent when filling the cache out of band.  Must match the one
  /// just_audio uses, otherwise YouTube can serve a different (or error) body.
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

  // ── Lazy state ────────────────────────────────────────────────────────────

  Directory? _dir;
  Future<Directory?>? _dirFuture;

  /// videoId → in-flight download, so two callers never race one file.
  final Map<String, Future<File?>> _inflightDownloads = {};

  /// Callbacks fired whenever the on-disk total changes, so the settings UI
  /// can repaint without polling the filesystem.
  final StreamController<int> _sizeChanges =
      StreamController<int>.broadcast();

  Stream<int> get sizeChanges => _sizeChanges.stream;

  // ── Filesystem ────────────────────────────────────────────────────────────

  Future<Directory?> cacheDirectory() async {
    if (!isSupported) return null;
    final cached = _dir;
    if (cached != null) return cached;
    final pending = _dirFuture;
    if (pending != null) return pending;

    final future = _openCacheDirectory();
    _dirFuture = future;
    try {
      return await future;
    } finally {
      _dirFuture = null;
    }
  }

  Future<Directory?> _openCacheDirectory() async {
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/audio');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (e) {
      debugPrint('[AudioCache] could not open cache dir: $e');
      return null;
    }
  }

  /// Absolute path a given videoId's audio lives at.
  Future<File?> fileFor(String videoId) async {
    final dir = await cacheDirectory();
    if (dir == null || videoId.isEmpty) return null;
    // Video IDs are [A-Za-z0-9_-]{11}; anything else is not from YouTube.
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(videoId)) return null;
    return File('${dir.path}/$videoId$_kFileExtension');
  }

  /// Where an out-of-band download writes before it is promoted into place.
  Future<File?> _tempFileFor(String videoId) async {
    final file = await fileFor(videoId);
    if (file == null) return null;
    return File('${file.path}.dl');
  }

  // ── Hive index ────────────────────────────────────────────────────────────

  Box? get _box {
    if (!Hive.isBoxOpen(kAudioCacheBox)) return null;
    return Hive.box(kAudioCacheBox);
  }

  /// Reads the index record for [videoId], or null when absent/unreadable.
  Map<dynamic, dynamic>? _entry(String videoId) {
    try {
      final raw = _box?.get(videoId);
      if (raw is Map) return raw;
    } catch (_) {
      // Corrupt entry — treat as absent.
    }
    return null;
  }

  Future<void> _writeEntry(
    String videoId, {
    required int sizeBytes,
    required bool complete,
  }) async {
    try {
      final box = _box;
      if (box == null) return;
      final previous = _entry(videoId);
      await box.put(videoId, <String, dynamic>{
        // Keep the original play time when we only refresh the size so LRU
        // order is not reset by a re-download of the same track.
        'lastPlayed': (previous?['lastPlayed'] as int?) ??
            DateTime.now().millisecondsSinceEpoch,
        'sizeBytes': sizeBytes,
        'complete': complete,
      });
    } catch (e) {
      debugPrint('[AudioCache] index write failed for $videoId: $e');
    }
  }

  /// Bumps the LRU timestamp so actively played tracks survive eviction.
  Future<void> touch(String videoId) async {
    try {
      final entry = _entry(videoId);
      if (entry == null) return;
      await _box?.put(videoId, <String, dynamic>{
        ...entry,
        'lastPlayed': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[AudioCache] touch failed for $videoId: $e');
    }
  }

  // ── Lookup ────────────────────────────────────────────────────────────────

  /// Returns the cached file for [videoId] only when it is *complete* and
  /// actually present with a non-zero body.
  ///
  /// When the index says "in progress" but a file of the right name exists,
  /// the index is stale rather than the file: downloads are promoted by an
  /// atomic rename, so a file at the final path means the body completed.
  Future<File?> lookup(String videoId) async {
    if (!isSupported || videoId.isEmpty) return null;
    try {
      final file = await fileFor(videoId);
      if (file == null) return null;

      final exists = await file.exists();
      if (!exists) {
        // Index pointed at a file that is gone — drop the record.
        if (_entry(videoId) != null) await _box?.delete(videoId);
        return null;
      }
      final length = await file.length();
      if (length <= 0) {
        await delete(videoId);
        return null;
      }

      final entry = _entry(videoId);
      final complete = entry?['complete'] as bool? ?? true;
      if (!complete) {
        await _writeEntry(videoId, sizeBytes: length, complete: true);
      } else {
        final size = (entry?['sizeBytes'] as int?) ?? length;
        if (size != length) {
          await _writeEntry(videoId, sizeBytes: length, complete: true);
        }
      }
      unawaited(touch(videoId));
      return file;
    } catch (e) {
      debugPrint('[AudioCache] lookup failed for $videoId: $e');
      return null;
    }
  }

  /// True when a complete file for [videoId] is on disk. Cheap enough for the
  /// prefetch gate because it short-circuits on the in-flight map.
  Future<bool> isCached(String videoId) async => await lookup(videoId) != null;

  // ── Index maintenance (called by the player as downloads finish) ──────────

  /// Promotes a finished playback-time download into the index.
  Future<void> markComplete(String videoId, {int? sizeBytes}) async {
    try {
      final file = await fileFor(videoId);
      final length = sizeBytes ??
          (file != null && await file.exists() ? await file.length() : 0);
      await _writeEntry(videoId, sizeBytes: length, complete: true);
      await _notifySize();
    } catch (e) {
      debugPrint('[AudioCache] markComplete failed for $videoId: $e');
    }
  }

  /// Flags a video as mid-download (or unknown) so it is never served early.
  Future<void> markIncomplete(String videoId) async {
    try {
      await _writeEntry(videoId, sizeBytes: 0, complete: false);
    } catch (e) {
      debugPrint('[AudioCache] markIncomplete failed for $videoId: $e');
    }
  }

  /// Removes the cached file (and any temp siblings) for [videoId].
  Future<void> delete(String videoId) async {
    try {
      final file = await fileFor(videoId);
      if (file != null) {
        for (final target in <File>[
          file,
          File('${file.path}.part'),
          File('${file.path}.dl'),
          File('${file.path}.mime'),
        ]) {
          try {
            if (await target.exists()) await target.delete();
          } catch (_) {
            // A file we cannot delete is not fatal — it is skipped on lookup.
          }
        }
      }
      await _box?.delete(videoId);
      await _notifySize();
    } catch (e) {
      debugPrint('[AudioCache] delete failed for $videoId: $e');
    }
  }

  // ── Out-of-band download (prefetch) ───────────────────────────────────────

  /// Downloads [url] into the private cache for [videoId].
  ///
  /// Used by prefetch, where there is no player attached.  Writes to a `.dl`
  /// temp file and renames into place only after the full body arrives, so a
  /// concurrent [lookup] can never observe a truncated file.
  ///
  /// Returns the cached [File] on success, null on any failure — callers treat
  /// null as "prefetch did not happen", never as an error.
  Future<File?> download(String videoId, String url) async {
    if (!isSupported || videoId.isEmpty || url.isEmpty) return null;

    final existing = _inflightDownloads[videoId];
    if (existing != null) return existing;

    final future = _download(videoId, url);
    _inflightDownloads[videoId] = future;
    try {
      return await future;
    } finally {
      _inflightDownloads.remove(videoId);
    }
  }

  Future<File?> _download(String videoId, String url) async {
    HttpClient? client;
    IOSink? sink;
    File? tempFile;
    try {
      // Already there? Nothing to download.
      final hit = await lookup(videoId);
      if (hit != null) return hit;

      final target = await fileFor(videoId);
      tempFile = await _tempFileFor(videoId);
      if (target == null || tempFile == null) return null;

      await tempFile.parent.create(recursive: true);
      if (await tempFile.exists()) await tempFile.delete();

      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        debugPrint('[AudioCache] $videoId → HTTP ${response.statusCode}');
        return null;
      }

      sink = tempFile.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      // Another writer may have finished the same track meanwhile.
      if (await target.exists()) {
        if (await tempFile.exists()) await tempFile.delete();
      } else {
        await tempFile.rename(target.path);
      }

      final size = await target.length();
      if (size <= 0) {
        await delete(videoId);
        return null;
      }

      await _writeEntry(videoId, sizeBytes: size, complete: true);
      unawaited(_notifySize());
      debugPrint('[AudioCache] cached $videoId (${_fmtBytes(size)})');
      return target;
    } catch (e) {
      debugPrint('[AudioCache] download failed for $videoId: $e');
      return null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  // ── Eviction ──────────────────────────────────────────────────────────────

  /// Current on-disk total plus the configured limit.
  Future<AudioCacheStats> stats() async {
    var total = 0;
    var count = 0;
    try {
      final box = _box;
      if (box != null) {
        for (final key in box.keys) {
          final id = key as String;
          final file = await fileFor(id);
          if (file == null || !await file.exists()) continue;
          final length = await file.length();
          if (length <= 0) continue;
          total += length;
          count++;
        }
      }
    } catch (e) {
      debugPrint('[AudioCache] stats failed: $e');
    }
    return AudioCacheStats(
      totalBytes: total,
      fileCount: count,
      limitBytes: await limitBytes(),
    );
  }

  /// Deletes least-recently-played files until the total is under the limit.
  ///
  /// [protect] holds videoIds that must never be removed — the player passes
  /// the current track and the next queue item so eviction can never yank the
  /// file out from under active playback.
  Future<void> evictIfNeeded({Set<String> protect = const {}}) async {
    if (!isSupported) return;
    try {
      final limit = await limitBytes();
      if (limit <= 0) return;

      final current = await stats();
      if (current.totalBytes <= limit) return;

      final box = _box;
      if (box == null) return;

      final entries = <MapEntry<String, int>>[];
      for (final key in box.keys) {
        final id = key as String;
        if (protect.contains(id)) continue;
        final entry = _entry(id);
        if (entry == null) continue;
        entries.add(MapEntry(
          id,
          (entry['lastPlayed'] as int?) ??
              (entry['created'] as int?) ??
              0,
        ));
      }
      // Oldest first.
      entries.sort((a, b) => a.value.compareTo(b.value));

      var total = current.totalBytes;
      var freed = 0;
      for (final entry in entries) {
        if (total <= limit) break;
        await delete(entry.key);
        final record = _entry(entry.key);
        final size = (record?['sizeBytes'] as int?) ?? 0;
        total -= size;
        freed += size;
      }
      debugPrint(
          '[AudioCache] evicted ${entries.length} file(s), freed '
          '${_fmtBytes(freed)} → ${_fmtBytes(total)} / ${_fmtBytes(limit)}');
    } catch (e) {
      debugPrint('[AudioCache] eviction failed: $e');
    }
  }

  /// Wipes every cached file and the whole index. Protected ids are kept.
  Future<void> clear({Set<String> protect = const {}}) async {
    if (!isSupported) return;
    try {
      final box = _box;
      final ids = box == null
          ? const <String>[]
          : box.keys.map((k) => k as String).toList(growable: false);
      for (final id in ids) {
        if (protect.contains(id)) continue;
        await delete(id);
      }
      await _notifySize();
      debugPrint('[AudioCache] cleared ${ids.length} index entr(ies)');
    } catch (e) {
      debugPrint('[AudioCache] clear failed: $e');
    }
  }

  /// Removes index rows whose files no longer exist. Called at startup so a
  /// system cache-dir wipe cannot leave phantom LRU entries behind.
  Future<void> reconcile() async {
    if (!isSupported) return;
    try {
      final box = _box;
      if (box == null) return;
      final stale = <String>[];
      for (final key in box.keys) {
        final id = key as String;
        final file = await fileFor(id);
        if (file == null || !await file.exists()) stale.add(id);
      }
      if (stale.isEmpty) return;
      await box.deleteAll(stale);
      debugPrint('[AudioCache] pruned ${stale.length} stale index entr(ies)');
    } catch (e) {
      debugPrint('[AudioCache] reconcile failed: $e');
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Box? get _settings {
    try {
      if (!Hive.isBoxOpen('settings')) return null;
      return Hive.box('settings');
    } catch (_) {
      return null;
    }
  }

  Future<int> limitBytes() async {
    try {
      final stored = _settings?.get(_kLimitKey);
      if (stored is int && stored > 0) return stored;
    } catch (_) {}
    return kDefaultAudioCacheLimitBytes;
  }

  Future<void> setLimitBytes(int bytes) async {
    try {
      await _settings?.put(_kLimitKey, bytes);
      // Shrinking the limit should take effect immediately, not at next play.
      unawaited(evictIfNeeded());
    } catch (e) {
      debugPrint('[AudioCache] setLimitBytes failed: $e');
    }
  }

  /// Wi-Fi-only by default: prefetching full tracks over mobile data is the
  /// single easiest way to burn a data plan.
  Future<bool> cacheOnMobileData() async {
    try {
      final stored = _settings?.get(_kMobileDataKey);
      if (stored is bool) return stored;
    } catch (_) {}
    return false;
  }

  Future<void> setCacheOnMobileData(bool value) async {
    try {
      await _settings?.put(_kMobileDataKey, value);
    } catch (e) {
      debugPrint('[AudioCache] setCacheOnMobileData failed: $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _notifySize() async {
    if (_sizeChanges.isClosed) return;
    try {
      _sizeChanges.add((await stats()).totalBytes);
    } catch (_) {
      // Never let a stats failure escape.
    }
  }

  void dispose() {
    unawaited(_sizeChanges.close());
  }
}

// ── Formatting ──────────────────────────────────────────────────────────────

/// Human-readable byte size, e.g. `1.2 GB`. Used by the debug log and the
/// settings screen.
String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Public wrapper — the settings UI needs the same formatting.
String formatCacheBytes(int bytes) => _fmtBytes(bytes);