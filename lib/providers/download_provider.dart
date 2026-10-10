// ============================================================
// providers/download_provider.dart
//
// Exposes DownloadService state to the UI via Riverpod.
//
// State
// ─────────────────────────────────────────────────────────────
// • DownloadState wraps the in-memory DownloadTask map and
//   the persisted DownloadIndexService together for a single
//   consistent view.
// • isDownloaded / isQueued / progressFor look at both layers.
//
// Architecture
// ─────────────────────────────────────────────────────────────
// StateNotifier keeps the provider pattern consistent with the
// rest of the codebase.  The notifier listens to the service's
// onChanged stream and rebuilds state on every change.
// ============================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/download_index.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/download_index_service.dart';
import '../services/download_service.dart';
import 'youtube_provider.dart';

// ── Service provider ──────────────────────────────────────────────────────────

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService(ref.watch(youtubeServiceProvider));
  ref.onDispose(service.dispose);
  return service;
});

// ── State ─────────────────────────────────────────────────────────────────────

class DownloadState {
  /// In-flight tasks (queued or actively downloading).
  final Map<String, DownloadTask> tasks;

  /// All completed downloads from the Hive index.
  final List<DownloadIndexEntry> downloaded;

  /// Optional error message (non-fatal — shown as a snackbar).
  final String? error;

  const DownloadState({
    this.tasks      = const {},
    this.downloaded = const [],
    this.error,
  });

  DownloadState copyWith({
    Map<String, DownloadTask>? tasks,
    List<DownloadIndexEntry>?  downloaded,
    String?                    error,
    bool                       clearError = false,
  }) {
    return DownloadState(
      tasks:      tasks      ?? this.tasks,
      downloaded: downloaded ?? this.downloaded,
      error:      clearError ? null : (error ?? this.error),
    );
  }

  // ── Convenience helpers ────────────────────────────────────────────────────

  bool isDownloaded(String videoId) =>
      DownloadIndexService.instance.isDownloaded(videoId);

  bool isQueued(String videoId) => tasks.containsKey(videoId);

  bool isDownloading(String videoId) {
    final task = tasks[videoId];
    return task != null && task.status == DownloadStatus.downloading;
  }

  bool isPaused(String videoId) {
    final task = tasks[videoId];
    return task != null && task.status == DownloadStatus.paused;
  }

  double progressFor(String videoId) => tasks[videoId]?.progress ?? 0.0;

  DownloadIndexEntry? indexEntry(String videoId) =>
      DownloadIndexService.instance.get(videoId);

  String? localPath(String videoId) =>
      DownloadIndexService.instance.get(videoId)?.path;

  /// Total bytes of all persisted downloads.
  int get totalSizeBytes => DownloadIndexService.instance.totalSizeBytes;
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class DownloadNotifier extends StateNotifier<DownloadState> {
  final DownloadService _service;
  StreamSubscription<void>? _sub;
  List<DownloadIndexEntry> _cachedDownloaded = const [];
  int _lastTaskCount = -1;

  DownloadNotifier(this._service) : super(const DownloadState()) {
    _cachedDownloaded = DownloadIndexService.instance.getAll();
    _sub = _service.onChanged.listen((_) => _rebuild());
    _rebuild(forceDownloaded: true);
  }

  void _rebuild({bool forceDownloaded = false}) {
    if (!mounted) return;
    final currentTasks = _service.tasksCopy;
    final taskCountChanged = currentTasks.length != _lastTaskCount;
    _lastTaskCount = currentTasks.length;

    // Only re-fetch all downloaded entries from Hive when a task finishes/removes,
    // or when explicitly requested (e.g. initial load, delete, retry).
    if (forceDownloaded || taskCountChanged) {
      _cachedDownloaded = DownloadIndexService.instance.getAll();
    }

    state = DownloadState(
      tasks:      Map.unmodifiable(currentTasks),
      downloaded: _cachedDownloaded,
    );
  }

  // ── Download actions ───────────────────────────────────────────────────────

  Future<void> downloadSong(Song song) async {
    try {
      await _service.downloadSong(song);
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          error: 'Download failed: ${e.toString().replaceAll('Exception: ', '')}',
        );
      }
    }
  }

  Future<void> downloadPlaylist(Playlist playlist) =>
      _service.downloadPlaylist(playlist);

  Future<void> downloadLikedSongs(List<Song> liked) =>
      _service.downloadLikedSongs(liked);

  void cancelDownload(String videoId)  => _service.cancelDownload(videoId);

  void pauseDownload(String videoId)   => _service.pauseDownload(videoId);

  void resumeDownload(String videoId)  => _service.resumeDownload(videoId);

  Future<void> retryDownload(String videoId) => _service.retryDownload(videoId);

  Future<void> deleteSong(String videoId) async {
    try {
      await _service.deleteSong(videoId);
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          error: 'Delete failed: ${e.toString().replaceAll('Exception: ', '')}',
        );
      }
    }
  }

  Future<void> deleteAllDownloads() => _service.deleteAllDownloads();

  // ── Settings ───────────────────────────────────────────────────────────────

  String get downloadQuality  => _service.downloadQuality;
  bool   get downloadOnMobile => _service.downloadOnMobile;

  Future<void> setDownloadQuality(String q)  => _service.setDownloadQuality(q);
  Future<void> setDownloadOnMobile(bool v)   => _service.setDownloadOnMobile(v);

  // ── Playlist auto-download ─────────────────────────────────────────────────

  Future<void> setPlaylistAutoDownload(
    String playlistId,
    bool enabled, {
    List<Song> currentSongs = const [],
  }) =>
      _service.setPlaylistAutoDownload(
        playlistId,
        enabled,
        currentSongs: currentSongs,
      );

  Future<bool> isPlaylistAutoDownload(String playlistId) =>
      _service.isPlaylistAutoDownload(playlistId);

  // ── Misc ──────────────────────────────────────────────────────────────────

  void clearError() => state = state.copyWith(clearError: true);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((ref) {
  return DownloadNotifier(ref.watch(downloadServiceProvider));
});
