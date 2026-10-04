// ============================================================
// services/ytmusic_feed_cache.dart
//
// Disk tier for the YouTube Music feeds (stale-while-revalidate).
//
// Why a second tier at all
// ─────────────────────────────────────────────────────────────
//   The in-memory map in YtMusicService is empty on every cold start, so a
//   cold launch has nothing to render while the InnerTube round-trip is in
//   flight. This store keeps the last good payload of each feed so the home
//   screen can paint immediately and refresh behind the user's back.
//
// Why the payload is stored as a JSON *string*
// ─────────────────────────────────────────────────────────────
//   Feeds are large nested structures (hundreds of songs, albums, playlists).
//   Hive's binary writer has to walk every node of a nested Map/List, and a
//   List<dynamic> read back out comes out as List<dynamic> rather than the
//   original generic type — which then fails an `is List<YtSong>` cast.
//   Storing one string sidesteps both problems: one contiguous write, and the
//   value is restored to plain JSON-compatible types by jsonDecode, so casts
//   behave. The encoding work is already being done for change detection, so
//   this costs nothing extra.
//
// Box: `ytmusic_feed_cache`  —  { key: { 'json': String, 'at': epoch ms } }
//
// Every operation is guarded. A cache problem must degrade to "no cached
// feed", never to a broken home screen.
// ============================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';

import '../platform/cache_support.dart';

const String kYtMusicFeedBox = 'ytmusic_feed_cache';

/// Feed payloads are capped so a pathological response cannot fill the user's
/// storage. A full home feed serialises to well under this.
const int kMaxFeedBytes = 4 * 1024 * 1024;

class YtMusicFeedCache {
  YtMusicFeedCache._();

  static final YtMusicFeedCache instance = YtMusicFeedCache._();

  /// False on desktop, where the whole caching system is disabled.
  bool get isEnabled => cacheSystemEnabled;

  Box? get _box {
    if (!isEnabled || !Hive.isBoxOpen(kYtMusicFeedBox)) return null;
    try {
      return Hive.box(kYtMusicFeedBox);
    } catch (_) {
      return null;
    }
  }

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Returns the decoded payload for [key], or null when there is nothing
  /// usable on disk.
  Future<Map<String, dynamic>?> read(String key) async {
    final box = _box;
    if (box == null) return null;
    try {
      final record = box.get(key);
      if (record is! Map) return null;
      final raw = record['json'];
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      // Corrupt row — drop it so the next write replaces it cleanly.
      debugPrint('[FeedCache] read failed for $key: $e');
      unawaited(delete(key));
    }
    return null;
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Persists [payload] for [key]. Returns without complaint if the cache is
  /// disabled, the box is closed, or the payload is too large.
  Future<void> write(String key, Map<String, dynamic> payload) async {
    final box = _box;
    if (box == null) return;
    try {
      final encoded = jsonEncode(payload);
      if (encoded.length > kMaxFeedBytes) {
        debugPrint('[FeedCache] skipping $key: '
            '${encoded.length} bytes exceeds cap');
        return;
      }
      await box.put(key, {
        'json': encoded,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[FeedCache] write failed for $key: $e');
    }
  }

  /// Removes a single feed, e.g. after a user-initiated refresh.
  Future<void> delete(String key) async {
    try {
      await _box?.delete(key);
    } catch (e) {
      debugPrint('[FeedCache] delete failed for $key: $e');
    }
  }

  /// Drops every cached feed.
  Future<void> clear() async {
    try {
      await _box?.clear();
      debugPrint('[FeedCache] cleared all cached feeds');
    } catch (e) {
      debugPrint('[FeedCache] clear failed: $e');
    }
  }

  // ── Housekeeping ──────────────────────────────────────────────────────────

  /// Total bytes used by the feed cache, for the settings screen.
  Future<int> totalBytes() async {
    final box = _box;
    if (box == null) return 0;
    var total = 0;
    try {
      for (final key in box.keys) {
        final record = box.get(key);
        if (record is Map && record['json'] is String) {
          total += (record['json'] as String).length;
        }
      }
    } catch (e) {
      debugPrint('[FeedCache] size scan failed: $e');
    }
    return total;
  }

  /// Drops rows that cannot be decoded any more.
  Future<int> pruneBroken() async {
    final box = _box;
    if (box == null) return 0;
    final broken = <String>[];
    try {
      for (final key in box.keys) {
        final record = box.get(key);
        final raw = record is Map ? record['json'] : null;
        if (raw is! String || raw.isEmpty) {
          broken.add(key.toString());
          continue;
        }
        try {
          jsonDecode(raw);
        } catch (_) {
          broken.add(key.toString());
        }
      }
      if (broken.isNotEmpty) await box.deleteAll(broken);
    } catch (e) {
      debugPrint('[FeedCache] prune failed: $e');
    }
    if (broken.isNotEmpty) {
      debugPrint('[FeedCache] pruned ${broken.length} unreadable feed(s)');
    }
    return broken.length;
  }
}
