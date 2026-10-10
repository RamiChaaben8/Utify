// ============================================================
// services/prefetch_service.dart
//
// Background warm-up of the next queue items.
//
// When a track starts, the next 1–2 queue items are warmed in the background
// in two stages:
//   1. Resolve the stream URL (cheap — a manifest round-trip that populates
//      the two-level URL cache).
//   2. Download the audio into the private file cache so the tap after next
//      is served straight off disk.
//
// Rules
// ─────────────────────────────────────────────────────────────
//   • Max 2 concurrent tasks — enough to hide latency, not enough to
//     compete with the track that is actually playing.
//   • Wi-Fi only by default. Mobile data is opt-in via the
//     "Cache on mobile data" setting.
//   • Any change to the queue cancels the previous generation of tasks,
//     because the old next-up items are no longer relevant.
//   • Nothing here can ever fail playback: every step is guarded and
//     cancellation is cooperative (checked between stages).
// ============================================================

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/song.dart';
import 'audio_cache_service.dart';
import 'youtube_service.dart';

/// How far ahead of the current track we warm.
const int kPrefetchDepth = 1;

/// Upper bound on simultaneous prefetch tasks.
const int kPrefetchMaxConcurrent = 2;

class PrefetchService {
  PrefetchService(this._youtube);

  final YoutubeService _youtube;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Incremented on every schedule()/cancel(). A task whose captured
  /// generation no longer matches the current one stops as soon as it can.
  int _generation = 0;

  /// Ids currently in flight, so a rescheduled task is not duplicated.
  final Set<String> _active = <String>{};

  /// Set of song ids that must not be evicted (current playing track + upcoming prefetched tracks).
  Set<String> _protect = <String>{};

  int _running = 0;
  bool _started = false;

  bool get _enabled => AudioCacheService.isSupported;

  // ── Connectivity ──────────────────────────────────────────────────────────

  bool _wifi = true;
  bool _wifiKnown = false;

  /// Begins watching connectivity. Cheap and idempotent; call it once at
  /// startup rather than on every track change.
  void start() {
    if (!_enabled || _started) return;
    _started = true;
    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen(
        _onConnectivityChanged,
        onError: (Object _) {
          // If we cannot tell, assume Wi-Fi and let the setting decide.
          _wifiKnown = false;
        },
      );
      unawaited(_probe());
    } catch (e) {
      debugPrint('[Prefetch] connectivity unavailable: $e');
    }
  }

  Future<void> _probe() async {
    try {
      _onConnectivityChanged(await Connectivity().checkConnectivity());
    } catch (e) {
      debugPrint('[Prefetch] connectivity probe failed: $e');
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final next = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    _wifi = next;
    _wifiKnown = true;
  }

  /// True when downloading ahead of the user is currently allowed.
  Future<bool> get isAllowed async {
    if (!_enabled) return false;
    try {
      if (await AudioCacheService.instance.cacheOnMobileData()) return true;
    } catch (_) {
      // Fall through to the Wi-Fi rule.
    }
    // With no connectivity information at all, allow the work — a phone that
    // reports "unknown" is usually on Wi-Fi, and the URL stage is tiny.
    if (!_wifiKnown) return true;
    return _wifi;
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  /// Cancels any pending tasks and queues [songs] for warming.
  ///
  /// Called on every track change. [protect] holds ids that must never be
  /// downloaded ahead of time (the current track and locally stored files).
  void schedule(List<Song> songs, {Set<String> protect = const {}}) async {
    cancel();
    if (!_enabled) return;

    _protect = {...protect, ...songs.map((s) => s.id)};
    final generation = _generation;
    final pending = <Song>[];
    for (final song in songs) {
      if (song.isLocal || song.localPath != null) continue;
      if (protect.contains(song.id)) continue;
      if (_active.contains(song.id)) continue;
      pending.add(song);
    }
    if (pending.isEmpty) return;

    final allowed = await isAllowed;
    if (generation != _generation) return;
    if (!allowed) {
      debugPrint('[Prefetch] skipped ${pending.length} item(s): not on Wi-Fi');
      return;
    }

    for (final song in pending.take(kPrefetchDepth)) {
      unawaited(_run(song, generation));
    }
  }

  /// Invalidates every in-flight task.
  void cancel() {
    _generation++;
  }

  Future<void> _run(Song song, int generation) async {
    if (_running >= kPrefetchMaxConcurrent) return;
    _active.add(song.id);
    _running++;
    try {
      // Already on disk — nothing to do.
      if (await AudioCacheService.instance.isCached(song.id)) return;
      if (generation != _generation) return;

      // ── Stage 1: stream URL ────────────────────────────────────────────
      final String url;
      try {
        url = await _youtube.getAudioStreamUrl(song.id).timeout(
              const Duration(seconds: 8),
            );
      } catch (e) {
        debugPrint('[Prefetch] URL stage failed for ${song.id}: $e');
        return;
      }
      if (generation != _generation) return;

      // ── Stage 2: audio file ────────────────────────────────────────────
      final file =
          await AudioCacheService.instance.download(song.id, url);
      if (file == null) return;
      if (generation != _generation) {
        // The queue moved on while we were downloading. The file is still
        // valid and worth keeping, so it stays cached — we just stop here.
        return;
      }
      debugPrint('[Prefetch] warmed ${song.id} for next-up');
      // Keep the cache under the user's limit after every warm.
      await trimCache();
    } catch (e) {
      debugPrint('[Prefetch] task failed for ${song.id}: $e');
    } finally {
      _running--;
      _active.remove(song.id);
    }
  }

  // ── Housekeeping ──────────────────────────────────────────────────────────

  /// Runs eviction after a warm download so the cache stays under the limit.
  Future<void> trimCache() async {
    try {
      await AudioCacheService.instance.evictIfNeeded(protect: _protect);
    } catch (e) {
      debugPrint('[Prefetch] trim failed: $e');
    }
  }

  void dispose() {
    cancel();
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
  }
}