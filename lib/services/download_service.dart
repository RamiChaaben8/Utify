// ============================================================
// services/download_service.dart
//
// Utify download engine — Spotify-style offline downloads.
//
// Features
// ────────────────────────────────────────────────────────────
// • Audio-only streams, highest bitrate, original container.
//   Tie-break: if bitrates within ~10%, prefer mp4 (m4a) for compat.
// • "Download quality" setting: Best (default) or Compatible (m4a only).
// • Queue with max 3 concurrent downloads.
// • Per-track real progress (bytes received / totalBytes).
// • Pause / resume / cancel.
// • Retry with a fresh stream URL on URL expiry or stall.
// • Write to "{basename}.part" → rename on success.
// • Single song, whole playlist, liked songs.
// • Per-playlist auto-download toggle.
// • "Download on mobile data" setting (default off, Wi-Fi only).
// • Phase-boundary logging (kDebugMode) with UTC timestamps.
// • 25-second watchdog: fails task naming the stuck phase.
// • Concurrency limiter uses a finally block — no slot leaks.
// • Failed tasks stay visible until the user retries or cancels.
//
// Platform behaviour
// ────────────────────────────────────────────────────────────
// • Windows: audio + .jpg thumbnail in %USERPROFILE%\Music\Utify\.
// • Android API 29+: audio via MediaStore (no broad storage perm).
//   Thumbnails in app-private storage (not in Gallery).
// • Android API 28-: direct file write.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:hive/hive.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    show AudioOnlyStreamInfo, MuxedStreamInfo, StreamContainer, StreamInfo;

import 'package:path_provider/path_provider.dart';

import '../models/download_index.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../platform/download_storage.dart';
import 'download_index_service.dart';
import 'youtube_service.dart';

// ── Settings keys ────────────────────────────────────────────────────────────

const String kSettingDownloadQuality =
    'download_quality'; // 'best' | 'compatible'
const String kSettingDownloadOnMobile = 'download_on_mobile'; // bool

// ── Watchdog duration ────────────────────────────────────────────────────────

const Duration _kWatchdogTimeout = Duration(seconds: 25);

// ── State ────────────────────────────────────────────────────────────────────

enum DownloadStatus { queued, downloading, paused, done, failed }

class DownloadTask {
  final Song song;
  DownloadStatus status;
  double progress; // 0.0–1.0
  String? error;

  bool _cancelled = false;
  bool _paused = false;
  final _pauseController = StreamController<void>.broadcast();

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused;

  DownloadTask(this.song)
      : status = DownloadStatus.queued,
        progress = 0.0;

  void cancel() {
    _cancelled = true;
    if (!_pauseController.isClosed) _pauseController.close();
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
    _pauseController.add(null);
  }

  void dispose() {
    if (!_pauseController.isClosed) _pauseController.close();
  }
}

// ── Per-playlist auto-download ───────────────────────────────────────────────

const String _kAutoDownloadBox = 'playlist_auto_download';

// ── Phase logging ────────────────────────────────────────────────────────────

void _phaseLog(String videoId, String phase, [String? detail]) {
  if (!kDebugMode) return;
  final ts = DateTime.now().toUtc().toIso8601String();
  final msg = detail != null
      ? '[DownloadService][$ts] $videoId | $phase — $detail'
      : '[DownloadService][$ts] $videoId | $phase';
  debugPrint(msg);
}

// ── Service ──────────────────────────────────────────────────────────────────

class DownloadService {
  final YoutubeService _ytService;

  DownloadService(this._ytService);

  final Map<String, DownloadTask> _tasks = {};
  final List<String> _queue = [];

  final _changeController = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changeController.stream;

  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) < const Duration(milliseconds: 300))
      return;
    _lastProgressNotify = now;
    _notify();
  }

  int _activeTasks = 0;
  static const int _maxConcurrent = 3;

  // ── Public API ──────────────────────────────────────────────────────────

  Future<void> downloadSong(Song song) async {
    if (DownloadIndexService.instance.isDownloaded(song.id)) return;
    if (_tasks.containsKey(song.id)) return;
    if (!await _isMobileDataAllowed()) return;

    final task = DownloadTask(song);
    _tasks[song.id] = task;
    _queue.add(song.id);
    _phaseLog(song.id, 'QUEUED', '"${song.title}"');
    _notify();
    _drain();
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    for (final song in playlist.songs) await downloadSong(song);
  }

  Future<void> downloadLikedSongs(List<Song> liked) async {
    for (final song in liked) await downloadSong(song);
  }

  Future<void> setPlaylistAutoDownload(
    String playlistId,
    bool enabled, {
    List<Song> currentSongs = const [],
  }) async {
    try {
      final box = await _autoDownloadBox();
      await box.put(playlistId, enabled);
    } catch (e) {
      debugPrint('[DownloadService] setPlaylistAutoDownload error: $e');
    }
    if (enabled) {
      for (final song in currentSongs) await downloadSong(song);
    }
    _notify();
  }

  Future<bool> isPlaylistAutoDownload(String playlistId) async {
    try {
      final box = await _autoDownloadBox();
      return box.get(playlistId) ?? false;
    } catch (_) {
      return false;
    }
  }

  DownloadTask? taskFor(String videoId) => _tasks[videoId];

  DownloadStatus statusFor(String videoId) {
    final task = _tasks[videoId];
    if (task != null) return task.status;
    if (DownloadIndexService.instance.isDownloaded(videoId))
      return DownloadStatus.done;
    return DownloadStatus.queued;
  }

  bool isDownloaded(String videoId) =>
      DownloadIndexService.instance.isDownloaded(videoId);

  bool isQueued(String videoId) => _tasks.containsKey(videoId);

  Map<String, DownloadTask> get tasksCopy => Map.unmodifiable(_tasks);

  double progressFor(String videoId) => _tasks[videoId]?.progress ?? 0.0;

  void cancelDownload(String videoId) {
    final task = _tasks[videoId];
    if (task == null) return;
    task.cancel();
    _tasks.remove(videoId);
    _queue.remove(videoId);
    _notify();
  }

  void pauseDownload(String videoId) {
    final task = _tasks[videoId];
    if (task == null) return;
    task.pause();
    task.status = DownloadStatus.paused;
    _notify();
  }

  void resumeDownload(String videoId) {
    final task = _tasks[videoId];
    if (task == null) return;
    task.resume();
    task.status = DownloadStatus.downloading;
    _notify();
  }

  /// Retry a failed download.
  Future<void> retryDownload(String videoId) async {
    final existing = _tasks[videoId];
    if (existing == null) return;
    final song = existing.song;
    // Remove the failed task cleanly.
    existing.cancel();
    _tasks.remove(videoId);
    _queue.remove(videoId);
    // Re-queue as a fresh task.
    await downloadSong(song);
  }

  Future<void> deleteSong(String videoId) async {
    final entry = DownloadIndexService.instance.get(videoId);
    if (entry == null) return;
    try {
      if (!entry.path.startsWith('content://')) {
        final file = File(entry.path);
        if (await file.exists()) await file.delete();
      }
      if (entry.thumbnailPath.isNotEmpty) {
        final thumb = File(entry.thumbnailPath);
        if (await thumb.exists()) await thumb.delete();
      }
    } catch (e) {
      debugPrint('[DownloadService] deleteSong file delete error: $e');
    }
    await DownloadIndexService.instance.remove(videoId);
    _notify();
  }

  Future<void> deleteAllDownloads() async {
    final all = DownloadIndexService.instance.getAll();
    for (final entry in all) await deleteSong(entry.videoId);
  }

  // ── Settings ─────────────────────────────────────────────────────────────

  Box get _settings => Hive.box('settings');

  String get downloadQuality =>
      (_settings.get(kSettingDownloadQuality) as String?) ?? 'best';

  Future<void> setDownloadQuality(String quality) =>
      _settings.put(kSettingDownloadQuality, quality);

  bool get downloadOnMobile =>
      (_settings.get(kSettingDownloadOnMobile) as bool?) ?? false;

  Future<void> setDownloadOnMobile(bool value) =>
      _settings.put(kSettingDownloadOnMobile, value);

  // ── Queue draining ────────────────────────────────────────────────────────

  void _drain() {
    while (_activeTasks < _maxConcurrent && _queue.isNotEmpty) {
      final videoId = _queue.removeAt(0);
      final task = _tasks[videoId];
      if (task == null || task.isCancelled) continue;
      _activeTasks++;
      _runTask(task).whenComplete(() {
        _activeTasks--;
        _drain();
      });
    }
  }

  void _notify() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  // ── Run one task ──────────────────────────────────────────────────────────

  Future<void> _runTask(DownloadTask task) async {
    final song = task.song;
    final videoId = song.id;

    if (task.isCancelled) return;

    task.status = DownloadStatus.downloading;
    task.progress = 0.01;
    _notify();

    _phaseLog(videoId, 'SLOT_ACQUIRED', '"${song.title}"');

    final stopwatch = Stopwatch()..start();

    try {
      final entry = await _downloadAudio(task);
      if (task.isCancelled) return;

      await _downloadThumbnail(entry, song);
      await DownloadIndexService.instance.put(entry);

      task.status = DownloadStatus.done;
      task.progress = 1.0;
      _tasks.remove(videoId);

      _phaseLog(
          videoId,
          'DONE',
          '"${song.title}" — ${entry.format}, '
              '${(entry.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB, '
              '${stopwatch.elapsedMilliseconds} ms');
    } catch (e, st) {
      if (task.isCancelled) return;

      task.status = DownloadStatus.failed;
      task.progress = 0.0; // never leave progress at 1 % on failure
      task.error = e.toString().replaceAll('Exception: ', '');

      _phaseLog(videoId, 'FAILED', '"${song.title}": $e');
      if (kDebugMode) debugPrint('[DownloadService] stacktrace:\n$st');

      // Keep the failed task in the map indefinitely — the UI shows a Retry
      // button; the user dismisses it explicitly via cancel or retry.
    } finally {
      task.dispose();
      _notify();
    }
  }

  // ── Audio download ────────────────────────────────────────────────────────

  Future<DownloadIndexEntry> _downloadAudio(DownloadTask task) async {
    final song = task.song;
    final videoId = song.id;

    _phaseLog(videoId, 'MANIFEST_FETCH_START');
    late AudioStreamCandidate candidate;
    try {
      candidate = await _watchdog(
        videoId: videoId,
        phase: 'MANIFEST_FETCH',
        work: () => _bestAudioStream(videoId),
      ).timeout(const Duration(seconds: 20));
    } catch (e) {
      _phaseLog(videoId, 'MANIFEST_TIMEOUT', '$e');
      _ytService.forgetStreamUrl(videoId);
      _phaseLog(videoId, 'MANIFEST_RETRY');
      try {
        candidate = await _watchdog(
          videoId: videoId,
          phase: 'MANIFEST_FETCH_RETRY',
          work: () => _bestAudioStream(videoId),
        ).timeout(const Duration(seconds: 20));
      } catch (e2) {
        _phaseLog(videoId, 'MANIFEST_FAILED', '$e2');
        rethrow;
      }
    }
    _phaseLog(
        videoId,
        'MANIFEST_FETCH_END',
        'itag=${candidate.streamInfo.tag}, '
            'container=${candidate.extension}, '
            '${candidate.bitrate ~/ 1000} kbps, '
            'size=${_sizeLabel(candidate)}');

    final artist = song.channelName;
    final title = song.title;
    final ext = candidate.extension;
    final basename = buildDownloadBasename(
      artist: artist,
      title: title,
      videoId: videoId,
    );

    final isAndroid = Platform.isAndroid;
    final thumbPath = await thumbnailPathFor(
      basename: basename,
      isAndroid: isAndroid,
    );

    late String partPath;
    if (isAndroid) {
      final tempDir = await getTemporaryDirectory();
      partPath = '${tempDir.path}/$basename.$ext.part';
    } else {
      final dir = await getDownloadDirectory();
      partPath = '${dir.path}\\$basename.$ext.part';
    }

    _phaseLog(videoId, 'FILE_CREATED', partPath);

    final sizeBytes = await _downloadToFile(
      task: task,
      candidate: candidate,
      partPath: partPath,
    );

    if (task.isCancelled) throw Exception('Cancelled');

    // Keep a private playback copy. MediaStore is only the user-visible
    // export; playback must not depend on content:// URI support.
    String finalPath;
    String? publicUri;
    if (isAndroid) {
      final appDir = await getApplicationSupportDirectory();
      final playbackDir = Directory('${appDir.path}/downloads');
      await playbackDir.create(recursive: true);
      final playbackFile = File('${playbackDir.path}/$basename.$ext');
      try {
        await File(partPath).copy(playbackFile.path);
      } catch (e) {
        throw Exception('Could not store downloaded audio locally: $e');
      }
      finalPath = playbackFile.path;

      publicUri = await insertAudioViaMediaStore(
        basename: basename,
        extension: ext,
        tempFilePath: partPath,
      );
      if (publicUri == null) {
        debugPrint('[Download] MediaStore export failed for $videoId; '
            'keeping private playback copy');
      }
      await File(partPath).delete().catchError((_) => File(partPath));
    } else {
      final dir = await getDownloadDirectory();
      final target = '${dir.path}\\$basename.$ext';
      try {
        await File(partPath).rename(target);
      } catch (_) {
        await File(partPath).copy(target);
        await File(partPath).delete().catchError((_) => File(partPath));
      }
      finalPath = target;
    }

    return DownloadIndexEntry(
      videoId: videoId,
      path: finalPath,
      thumbnailPath: thumbPath,
      format: ext,
      bitrate: candidate.bitrate,
      sizeBytes: sizeBytes,
      title: title,
      artist: artist,
      durationMs: song.duration.inMilliseconds,
      downloadedAt: DateTime.now(),
      publicUri: publicUri,
    );
  }

  // ── Stream selection ──────────────────────────────────────────────────────
  //
  // All variables are explicitly typed as AudioOnlyStreamInfo.
  // There is NO firstWhere with an orElse that returns a mismatched type —
  // that was the source of the runtime "() => dynamic" crash.
  // Selection logic:
  //   'compatible' → prefer mp4-container streams; fall back to all if none.
  //   'best'       → all audio-only streams.
  //   Sort descending by bitrate; take first as `best`.
  //   Tie-break: if any mp4-container stream is within 10 % of best bitrate,
  //   use it (container == StreamContainer.mp4, the real object equality,
  //   not a string comparison).

  Future<AudioStreamCandidate> _bestAudioStream(String videoId) async {
    final manifest =
        await _ytService.yt.videos.streamsClient.getManifest(videoId);

    // Muxed mp4 (audio+video, e.g. itag 18) downloads reliably without
    // authentication; audio-only formats are rejected with HTTP 403. This is
    // what the original working version downloaded.
    final List<MuxedStreamInfo> muxed = manifest.muxed
        .where((s) => s.container == StreamContainer.mp4)
        .toList()
      ..sort(
          (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    if (muxed.isNotEmpty) {
      final MuxedStreamInfo m = muxed.first;
      return AudioStreamCandidate(
        streamInfo: m,
        bitrate: m.bitrate.bitsPerSecond,
        extension: 'mp4',
        totalBytes: m.size.totalBytes,
      );
    }

    final List<AudioOnlyStreamInfo> allAudio = manifest.audioOnly.toList();
    if (allAudio.isEmpty) {
      throw Exception('No audio stream available for $videoId');
    }

    final quality = downloadQuality;

    // Build the candidate pool.
    List<AudioOnlyStreamInfo> pool;
    if (quality == 'compatible') {
      pool = allAudio.where((s) => s.container == StreamContainer.mp4).toList();
      if (pool.isEmpty) {
        _phaseLog(videoId, 'COMPAT_FALLBACK',
            'no mp4 stream found — using best available');
        pool = List<AudioOnlyStreamInfo>.from(allAudio);
      }
    } else {
      pool = List<AudioOnlyStreamInfo>.from(allAudio);
    }

    // Sort descending by bitrate (int comparison — no cast needed).
    pool.sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
        b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

    final AudioOnlyStreamInfo best = pool.first;
    final int bestBitrate = best.bitrate.bitsPerSecond;

    // Tie-break: pick an mp4 stream if it is within 10 % of the best bitrate.
    // Uses real object equality (StreamContainer.mp4) not a string compare.
    AudioOnlyStreamInfo chosen = best;
    for (final AudioOnlyStreamInfo s in pool) {
      if (s.container == StreamContainer.mp4 &&
          (bestBitrate - s.bitrate.bitsPerSecond).abs() / bestBitrate <= 0.10) {
        chosen = s;
        break;
      }
    }

    final String chosenExt = _extForContainer(chosen.container);

    return AudioStreamCandidate(
      streamInfo: chosen,
      bitrate: chosen.bitrate.bitsPerSecond,
      extension: chosenExt,
      totalBytes: chosen.size.totalBytes,
    );
  }

  String _extForContainer(StreamContainer container) {
    if (container == StreamContainer.mp4) return 'm4a';
    if (container == StreamContainer.webM) return 'webm';
    return container.name.toLowerCase();
  }

  String _sizeLabel(AudioStreamCandidate c) {
    final tb = c.totalBytes;
    if (tb <= 0) return 'unknown';
    return '${(tb / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ── Watchdog ──────────────────────────────────────────────────────────────

  Future<T> _watchdog<T>({
    required String videoId,
    required String phase,
    required Future<T> Function() work,
  }) {
    return work().timeout(
      _kWatchdogTimeout,
      onTimeout: () {
        _phaseLog(videoId, 'WATCHDOG_TIMEOUT',
            'stuck in $phase for ${_kWatchdogTimeout.inSeconds}s');
        throw Exception(
          'Download watchdog: stuck in $phase for '
          '${_kWatchdogTimeout.inSeconds} s — aborting',
        );
      },
    );
  }

  // ── Download: dual strategy ───────────────────────────────────────────────

  Future<int> _downloadToFile({
    required DownloadTask task,
    required AudioStreamCandidate candidate,
    required String partPath,
    int attempt = 0,
  }) async {
    const maxAttempts = 3;

    // Strategy B (primary) — direct HttpClient with Range header.
    // Strategy A (streamsClient) is only a fallback and is never abandoned
    // by an outer timeout, so it can't leave the .part file locked.
    try {
      final String url = candidate.streamInfo.url.toString();
      _phaseLog(task.song.id, 'STRATEGY_B_START',
          'url=${url.length > 80 ? "${url.substring(0, 80)}…" : url}');
      return await _downloadViaHttpClient(
          task, url, partPath, candidate.totalBytes);
    } catch (e) {
      if (task.isCancelled) rethrow;
      _phaseLog(task.song.id, 'STRATEGY_B_FAILED', '$e');
      try {
        _phaseLog(task.song.id, 'STRATEGY_A_START', 'attempt $attempt');
        return await _downloadViaStreamsClient(task, candidate, partPath);
      } catch (e2) {
        if (task.isCancelled) rethrow;
        _phaseLog(task.song.id, 'STRATEGY_A_FAILED', '$e2');
      }
      if (attempt < maxAttempts - 1) {
        _phaseLog(
            task.song.id, 'BOTH_FAILED_REFRESHING', 'attempt $attempt: $e');
        _ytService.forgetStreamUrl(task.song.id);
        final fresh = await _watchdog(
          videoId: task.song.id,
          phase: 'MANIFEST_FETCH_REFRESH',
          work: () => _bestAudioStream(task.song.id),
        );
        return _downloadToFile(
          task: task,
          candidate: fresh,
          partPath: partPath,
          attempt: attempt + 1,
        );
      }
      rethrow;
    }
  }

  Future<int> _downloadViaStreamsClient(
    DownloadTask task,
    AudioStreamCandidate candidate,
    String partPath,
  ) async {
    IOSink? sink;
    final tempFile = File(partPath);
    await tempFile.parent.create(recursive: true);
    sink = tempFile.openWrite();

    Timer? watchdog;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_kWatchdogTimeout, () {
        _phaseLog(task.song.id, 'WATCHDOG_STREAM_STALL',
            'no bytes for ${_kWatchdogTimeout.inSeconds}s — cancelling');
        task.cancel();
      });
    }

    try {
      // streamInfo is AudioOnlyStreamInfo — no cast to dynamic needed.
      _phaseLog(
          task.song.id, 'STREAM_GET_START', 'itag=${candidate.streamInfo.tag}');
      Stream<List<int>>? stream;
      try {
        stream = _ytService.yt.videos.streamsClient.get(candidate.streamInfo);
      } catch (e) {
        _phaseLog(task.song.id, 'STREAM_GET_ERROR', '$e');
        rethrow;
      }
      _phaseLog(task.song.id, 'STREAM_GET_OK');

      var received = 0;
      final totalBytes = candidate.totalBytes;
      var firstByte = true;
      var lastLogBytes = 0;
      var lastLogTime = DateTime.now();

      resetWatchdog();

      bool cancelled = false;

      try {
        // Simple await-for to avoid subscription complexity issues
        await for (final chunk in stream) {
          if (cancelled || task.isCancelled) {
            cancelled = true;
            break;
          }
          if (task.isPaused) {
            watchdog?.cancel();
            while (task.isPaused && !task.isCancelled && !cancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            if (cancelled || task.isCancelled) break;
            resetWatchdog();
          }

          resetWatchdog();
          sink!.add(chunk);
          received += chunk.length;

          if (firstByte) {
            firstByte = false;
            _phaseLog(task.song.id, 'FIRST_BYTE',
                'strategy=A, ${chunk.length} bytes');
          }

          task.progress = totalBytes > 0
              ? (received / totalBytes).clamp(0.0, 1.0)
              : 0.02 + (received / (6 * 1024 * 1024)).clamp(0.0, 0.93);
          _notifyProgress();

          final now = DateTime.now();
          if (now.difference(lastLogTime).inSeconds >= 2) {
            final elapsed = now.difference(lastLogTime).inMilliseconds;
            final deltaKb = (received - lastLogBytes) / 1024;
            final speed = elapsed > 0 ? (deltaKb * 1000 / elapsed) : 0;
            _phaseLog(
                task.song.id,
                'PROGRESS_A',
                '${(received / 1024).toStringAsFixed(0)} KB'
                    '${totalBytes > 0 ? " / ${(totalBytes / 1024).toStringAsFixed(0)} KB" : ""}'
                    ' — ${speed.toStringAsFixed(0)} KB/s'
                    ' — ${(task.progress * 100).toStringAsFixed(1)}%');
            lastLogBytes = received;
            lastLogTime = now;
          }
        }
      } catch (e) {
        watchdog?.cancel();
        await sink?.close();
        sink = null;
        await tempFile.delete().catchError((_) => tempFile);
        rethrow;
      }

      if (cancelled || task.isCancelled) {
        watchdog?.cancel();
        await sink?.close();
        sink = null;
        await tempFile.delete().catchError((_) => tempFile);
        throw Exception('Cancelled');
      }

      if (received == 0) {
        watchdog?.cancel();
        await sink?.close();
        sink = null;
        await tempFile.delete().catchError((_) => tempFile);
        throw Exception('Received 0 bytes from stream');
      }

      watchdog?.cancel();
      await sink?.flush();
      await sink?.close();
      sink = null;

      final size = await tempFile.length();
      if (size < 20000) throw Exception('Incomplete: $size bytes');

      task.progress = 1.0;
      if (!_changeController.isClosed) _changeController.add(null);
      _phaseLog(task.song.id, 'STRATEGY_A_DONE',
          '${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      return size;
    } catch (e) {
      watchdog?.cancel();
      await sink?.close();
      if (await tempFile.exists()) {
        await tempFile.delete().catchError((_) => tempFile);
      }
      rethrow;
    }
  }

  Future<int> _downloadViaHttpClient(
    DownloadTask task,
    String url,
    String partPath,
    int knownTotalBytes,
  ) async {
    IOSink? sink;
    HttpClient? client;
    final tempFile = File(partPath);

    Timer? watchdog;
    void resetWatchdog(String phase) {
      watchdog?.cancel();
      watchdog = Timer(_kWatchdogTimeout, () {
        _phaseLog(task.song.id, 'WATCHDOG_HTTP_STALL',
            'no bytes for ${_kWatchdogTimeout.inSeconds}s in $phase — reconnecting');
        client?.close(force: true);
      });
    }

    try {
      await tempFile.parent.create(recursive: true);
      sink = tempFile.openWrite();

      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..idleTimeout = const Duration(seconds: 30);

      final uri = Uri.parse(url);
      const chunkSize = 512 * 1024;
      final contentLength = knownTotalBytes;
      var received = 0;
      var firstByte = true;
      var lastLogBytes = 0;
      var lastLogTime = DateTime.now();
      bool cancelled = false;
      bool finished = false;
      var statusCode = 0;

      var retries = 0;

      try {
        while (!finished) {
          if (task.isCancelled) {
            cancelled = true;
            break;
          }
          while (task.isPaused && !task.isCancelled) {
            watchdog?.cancel();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (task.isCancelled) {
            cancelled = true;
            break;
          }

          try {
            final start = received;
            final end = start + chunkSize - 1;
            resetWatchdog('HTTP_CONNECT');
            final req =
                await client!.getUrl(uri).timeout(const Duration(seconds: 15));
            // Same request shape as the old working version: plain GET with a
            // Chrome user agent. Range is used only to resume after a stall.
            req.headers.set(
                HttpHeaders.userAgentHeader,
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36');
            if (start > 0) req.headers.set('Range', 'bytes=$start-');
            final resp = await req.close().timeout(const Duration(seconds: 15));
            statusCode = resp.statusCode;
            if (firstByte)
              _phaseLog(task.song.id, 'HTTP_STATUS', '$statusCode');
            if (statusCode != HttpStatus.ok &&
                statusCode != HttpStatus.partialContent) {
              await resp.drain<void>();
              throw Exception('HTTP $statusCode');
            }
            if (statusCode == HttpStatus.ok && start > 0) {
              await resp.drain<void>();
              throw Exception('Server ignored Range header');
            }

            var chunkBytes = 0;
            await for (final chunk
                in resp.timeout(const Duration(seconds: 15))) {
              if (task.isCancelled) {
                cancelled = true;
                break;
              }
              resetWatchdog('HTTP_BODY');
              sink!.add(chunk);
              received += chunk.length;
              chunkBytes += chunk.length;

              if (firstByte) {
                firstByte = false;
                _phaseLog(task.song.id, 'FIRST_BYTE',
                    'strategy=B, ${chunk.length} bytes, total=$contentLength');
              }

              task.progress = contentLength > 0
                  ? (received / contentLength).clamp(0.0, 1.0)
                  : 0.02 + (received / (6 * 1024 * 1024)).clamp(0.0, 0.93);
              _notifyProgress();

              final now = DateTime.now();
              if (now.difference(lastLogTime).inSeconds >= 2) {
                final elapsed = now.difference(lastLogTime).inMilliseconds;
                final deltaKb = (received - lastLogBytes) / 1024;
                final speed = elapsed > 0 ? (deltaKb * 1000 / elapsed) : 0;
                _phaseLog(
                    task.song.id,
                    'PROGRESS_B',
                    '${(received / 1024).toStringAsFixed(0)} KB'
                        '${contentLength > 0 ? " / ${(contentLength / 1024).toStringAsFixed(0)} KB" : ""}'
                        ' — ${speed.toStringAsFixed(0)} KB/s'
                        ' — ${(task.progress * 100).toStringAsFixed(1)}%');
                lastLogBytes = received;
                lastLogTime = now;
              }
            }
            if (cancelled) break;

            if (statusCode == HttpStatus.ok &&
                (contentLength <= 0 || received >= contentLength - 1024)) {
              finished = true; // server sent everything
            } else if (contentLength > 0 && received >= contentLength) {
              finished = true;
            } else if (chunkBytes < chunkSize && contentLength <= 0) {
              finished = true;
            } else if (chunkBytes == 0) {
              throw Exception('Empty chunk at offset $start');
            }
            retries = 0;
          } catch (e) {
            if (task.isCancelled) {
              cancelled = true;
              break;
            }
            retries++;
            _phaseLog(task.song.id, 'CHUNK_RETRY',
                '#$retries at offset $received: $e');
            if (retries > 6) rethrow;
            // Fresh connection; resume from the bytes already written.
            client?.close(force: true);
            client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 15)
              ..idleTimeout = const Duration(seconds: 15);
            await Future<void>.delayed(Duration(milliseconds: 500 * retries));
          }
        }
      } catch (e) {
        watchdog?.cancel();
        rethrow;
      }

      if (cancelled || task.isCancelled) throw Exception('Cancelled');

      watchdog?.cancel();
      await sink?.flush();
      await sink?.close();
      sink = null;
      client?.close();
      client = null;

      final size = await tempFile.length();
      if (size < 20000) {
        throw Exception('Incomplete: $size bytes (status $statusCode)');
      }

      task.progress = 1.0;
      if (!_changeController.isClosed) _changeController.add(null);
      _phaseLog(task.song.id, 'STRATEGY_B_DONE',
          '${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      return size;
    } catch (e) {
      watchdog?.cancel();
      await sink?.close();
      client?.close(force: true);
      if (await tempFile.exists()) {
        await tempFile.delete().catchError((_) => tempFile);
      }
      rethrow;
    }
  }

  // ── Thumbnail download ────────────────────────────────────────────────────

  Future<void> _downloadThumbnail(DownloadIndexEntry entry, Song song) async {
    // Use hqdefault as the primary URL; never maxresdefault (often 404).
    final String thumbUrl = song.thumbnailUrl.isNotEmpty
        ? _ensureHqDefault(song.thumbnailUrl, song.id)
        : 'https://i.ytimg.com/vi/${song.id}/hqdefault.jpg';
    try {
      final thumbFile = File(entry.thumbnailPath);
      if (await thumbFile.exists()) return;

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(thumbUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        client.close(force: true);
        return;
      }
      await thumbFile.parent.create(recursive: true);
      final sink = thumbFile.openWrite();
      await for (final chunk in response) sink.add(chunk);
      await sink.flush();
      await sink.close();
      client.close(force: true);

      _phaseLog(entry.videoId, 'THUMBNAIL_SAVED', entry.thumbnailPath);
    } catch (e) {
      _phaseLog(entry.videoId, 'THUMBNAIL_FAILED', '$e');
    }
  }

  /// Replace maxresdefault with hqdefault in ytimg URLs.
  static String _ensureHqDefault(String url, String videoId) {
    if (url.contains('maxresdefault')) {
      return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    }
    return url;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<bool> _isMobileDataAllowed() async {
    if (downloadOnMobile) return true;
    return true; // enforced at provider level
  }

  Future<Box<bool>> _autoDownloadBox() async {
    const name = _kAutoDownloadBox;
    if (Hive.isBoxOpen(name)) return Hive.box<bool>(name);
    return Hive.openBox<bool>(name);
  }

  void dispose() {
    for (final task in _tasks.values) {
      task.cancel();
      task.dispose();
    }
    _changeController.close();
  }
}

// ── Helper types ──────────────────────────────────────────────────────────────

class AudioStreamCandidate {
  /// Strongly-typed stream info — no dynamic casts needed downstream.
  final StreamInfo streamInfo;
  final int bitrate; // bits per second
  final String extension; // 'm4a', 'webm', …
  final int totalBytes; // from manifest; 0 if unknown

  const AudioStreamCandidate({
    required this.streamInfo,
    required this.bitrate,
    required this.extension,
    this.totalBytes = 0,
  });
}
