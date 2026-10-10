// ============================================================
// services/audio_player_service.dart
// ============================================================

// LockCachingAudioSource is just_audio's built-in download-to-disk source and
// is the API this service is built around, but it is still tagged
// @experimental upstream. Suppressed here only; the rest of the project is
// unaffected.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart' show WidgetsBinding, precacheImage;
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import 'artwork_cache_manager.dart';
import 'audio_cache_service.dart';
import 'download_index_service.dart';
import 'prefetch_service.dart';
import 'youtube_service.dart';



class AudioPlayerService {
  static const _streamAttemptTimeout = Duration(seconds: 7);
  static const _localSourceTimeout = Duration(seconds: 3);
  static const _maxStreamsPerLoad = 3;

  /// Private audio file cache is an Android-only feature. Desktop keeps the
  /// exact stream-everything path it has today.
  static bool get _cacheEnabled => AudioCacheService.isSupported;
  // Build platform-appropriate load config.
  // AndroidLoadControl must only be passed on Android — the type is harmless
  // to reference in Dart but passing it causes an assertion inside just_audio
  // on non-Android platforms.
  static AudioLoadConfiguration? _loadConfig() {
    if (Platform.isAndroid) {
      return const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 10),
          maxBufferDuration: Duration(seconds: 30),
          prioritizeTimeOverSizeThresholds: true,
          targetBufferBytes: 32 * 1024,
        ),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return const AudioLoadConfiguration(
        darwinLoadControl: DarwinLoadControl(
          preferredForwardBufferDuration: Duration(seconds: 5),
          automaticallyWaitsToMinimizeStalling: false,
        ),
      );
    }
    // Windows / Linux — media_kit backend, no load config needed.
    return null;
  }

  final AudioPlayer _player = AudioPlayer(
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
    audioLoadConfiguration: _loadConfig(),
  );

  final YoutubeService _youtube;

  /// Warms the next queue items off the critical path. Created lazily because
  /// the service needs [_youtube], which arrives via the constructor.
  late final PrefetchService _prefetch = PrefetchService(_youtube);

  List<Song> _queue = [];
  int _currentIndex = -1;
  bool _shuffle = false;
  List<Song>? _unshuffledQueue;
  final Set<int> _shufflePlayed = {};
  final Random _random = Random();
  LoopMode _loopMode = LoopMode.off;
  double _volume = 1.0;

  StreamSubscription<PlayerState>? _completionSub;
  StreamSubscription<PlaybackEvent>? _playbackErrorSub;
  Timer? _startupWatchdog;
  StreamSubscription<PlayerState>? _firstAudioSub;

  /// True while the current load is reading a file from the private audio
  /// cache. A playback error on a cached file is almost always a corrupt or
  /// partial write, so we delete it and retry once over the network.
  bool _loadedFromCache = false;

  /// Bumped once per cache-corruption recovery so we never loop deleting and
  /// reloading the same file.
  bool _cacheRetryUsed = false;

  // Serial counter — incremented on every _loadAndPlay call.
  // Used by the setAudioSource callback to discard itself if superseded.
  int _loadSerial = 0;

  /// Last song for which we precached artwork.
  String? _lastArtworkPrecached;
  int? _recoveringSerial;

  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  /// Emits the new current song's id every time the track changes
  /// (auto-skip, manual skip, or play a new song).
  final StreamController<Song> _songChangeController =
      StreamController<Song>.broadcast();
  Stream<Song> get songChangeStream => _songChangeController.stream;

  AudioPlayerService(this._youtube);

  double get volume => _volume;

  /// Restore the last local volume before the app starts accepting playback.
  Future<void> initialize() async {
    final settings = Hive.box('settings');
    final saved = settings.get('volume');
    if (saved is num) {
      _volume = saved.toDouble().clamp(0.0, 1.0);
    }
    await _player.setVolume(_volume);
    // Start watching connectivity so the first prefetch decision does not have
    // to wait on a platform round-trip.
    _prefetch.start();
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;

  AudioPlayer get player => _player;
  YoutubeService get youtubeService => _youtube;
  List<Song> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  bool get shuffle => _shuffle;
  LoopMode get loopMode => _loopMode;

  Song? get currentSong => (_currentIndex >= 0 && _currentIndex < _queue.length)
      ? _queue[_currentIndex]
      : null;

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    if (queue != null) {
      _queue = List.from(queue);
      _currentIndex = _queue.indexWhere((s) => s.id == song.id);
      if (_currentIndex == -1) {
        _queue.insert(0, song);
        _currentIndex = 0;
      }
      if (_shuffle) {
        // Capture the incoming order as the baseline before anything is
        // reshuffled, so turning shuffle off restores the real playlist order.
        _reconcileShuffleBaseline(_queue);
        // Jumping into the middle of a list would otherwise strand everything
        // above the picked track behind the playhead, where it can never show
        // up as "Next Up". Move those tracks to the end of the queue instead.
        _rotateStrandedToEnd();
        _shuffleAhead();
      } else {
        _unshuffledQueue = null;
      }
      _shufflePlayed
        ..clear()
        ..add(_currentIndex);
    } else {
      if (!_queue.any((s) => s.id == song.id)) {
        _queue = [song];
        _currentIndex = 0;
      } else {
        _currentIndex = _queue.indexWhere((s) => s.id == song.id);
      }
    }
    await _loadAndPlay(_currentIndex);
  }

  void addToQueue(Song song) {
    if (!_queue.any((s) => s.id == song.id)) {
      _queue.add(song);
      _prefetch.cancel();
    }
  }

  void setQueue(List<Song> queue, {int? currentIndex}) {
    _queue = List.from(queue);
    if (_shuffle) _reconcileShuffleBaseline(_queue);
    if (_queue.isEmpty) {
      _currentIndex = -1;
    } else if (currentIndex != null) {
      _currentIndex = currentIndex.clamp(0, _queue.length - 1);
    }
    // The next-up set just changed; drop anything scheduled for the old one.
    _prefetch.cancel();
  }

  void playNext(Song song) {
    _queue.removeWhere((s) => s.id == song.id);
    final insertAt = (_currentIndex + 1).clamp(0, _queue.length);
    _queue.insert(insertAt, song);
    _prefetch.cancel();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) _currentIndex--;
    _prefetch.cancel();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);
    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    _prefetch.cancel();
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    await Hive.box('settings').put('volume', _volume);
  }

  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    int next;
    if (_shuffle && _queue.length > 1) {
      next = -1;
      // Play forward through the shuffled queue in the same order it is
      // displayed. This prevents random jumps back into already-passed rows.
      for (var offset = 1; offset < _queue.length; offset++) {
        final candidate = (_currentIndex + offset) % _queue.length;
        if (!_shufflePlayed.contains(candidate)) {
          next = candidate;
          break;
        }
      }
      if (next == -1) {
        _shufflePlayed
          ..clear()
          ..add(_currentIndex);
        final candidates = List<int>.generate(_queue.length, (index) => index)
            .where((index) => index != _currentIndex)
            .toList();
        next = candidates[_random.nextInt(candidates.length)];
      }
      _shufflePlayed.add(next);
    } else {
      next = (_currentIndex + 1) % _queue.length;
    }
    _currentIndex = next;
    await _loadAndPlay(_currentIndex);
  }

  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    await _loadAndPlay(_currentIndex);
  }

  /// Shuffle everything still ahead of the current track.
  ///
  /// The track that is playing keeps its position so enabling shuffle never
  /// interrupts it.
  void _shuffleAhead() {
    for (var i = _queue.length - 1; i > _currentIndex + 1; i--) {
      final j = _currentIndex + 1 + _random.nextInt(i - _currentIndex);
      final song = _queue[i];
      _queue[i] = _queue[j];
      _queue[j] = song;
    }
  }

  /// Move every track above the current one to the end of the queue.
  ///
  /// The queue panel only lists [currentIndex + 1 .. end] as "Next Up", so
  /// anything before the current track is invisible and unplayable unless it is
  /// relocated. After this the picked track is first and everything else — the
  /// songs that were "missed" as well as the ones ahead — sits ahead of it,
  /// ready to be shuffled in.
  void _rotateStrandedToEnd() {
    if (_currentIndex <= 0) return;
    final stranded = _queue.sublist(0, _currentIndex);
    _queue.removeRange(0, _currentIndex);
    _queue.addAll(stranded);
    _currentIndex = 0;
  }

  void toggleShuffle() {
    if (!_shuffle) {
      _unshuffledQueue = List<Song>.from(_queue);
      _shuffleAhead();
      _shuffle = true;
    } else {
      final currentId = currentSong?.id;
      final original = _unshuffledQueue;
      if (original != null) {
        _queue = List<Song>.from(original);
        final restoredIndex = currentId == null
            ? -1
            : _queue.indexWhere((song) => song.id == currentId);
        if (restoredIndex >= 0) _currentIndex = restoredIndex;
      }
      _unshuffledQueue = null;
      _shuffle = false;
    }
    _shufflePlayed
      ..clear()
      ..addAll(_shuffle && _currentIndex >= 0
          ? Iterable<int>.generate(_currentIndex + 1)
          : [_currentIndex]);
  }

  void toggleLoopMode() {
    switch (_loopMode) {
      case LoopMode.off:
        _loopMode = LoopMode.all;
        _player.setLoopMode(LoopMode.all);
        break;
      case LoopMode.all:
        _loopMode = LoopMode.one;
        _player.setLoopMode(LoopMode.one);
        break;
      case LoopMode.one:
        _loopMode = LoopMode.off;
        _player.setLoopMode(LoopMode.off);
        break;
    }
  }

  // ── Core load ────────────────────────────────────────────────────────────

  Future<void> _loadAndPlay(
    int index, {
    Set<String> failedStreamUrls = const {},
    bool isCacheRetry = false,
  }) async {
    if (index < 0 || index >= _queue.length) return;

    final song = _queue[index];
    _youtube.seedFromSong(song);

    _completionSub?.cancel();
    _completionSub = null;
    _playbackErrorSub?.cancel();
    _playbackErrorSub = null;
    _firstAudioSub?.cancel();
    _firstAudioSub = null;
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    _loadedFromCache = false;
    // A fresh track gets a fresh corruption budget; the in-flight cache retry
    // keeps the one it already spent.
    if (!isCacheRetry) _cacheRetryUsed = false;

    // Tap-to-first-audio instrumentation. Started before the first await so
    // the number covers URL resolution, file I/O and decoder spin-up.
    final tapWatch = Stopwatch()..start();

    // Stamp this load. If another _loadAndPlay starts before setAudioSource
    // resolves, the stale callback will see a different serial and skip play().
    final mySerial = ++_loadSerial;

    final mediaItem = MediaItem(
      id: song.id,
      title: song.title,
      artist: song.channelName,
      duration: song.duration,
      artUri:
          song.thumbnailUrl.isNotEmpty ? Uri.parse(song.thumbnailUrl) : null,
    );

    // ── Source resolution: download index → cache → network ──────────────
    //
    // RULE: if a song is in the download index, always play the local file.
    // Never trigger stream URL resolution for a downloaded song.
    final downloadEntry = DownloadIndexService.instance.get(song.id);
    String? localPath;
    bool    sourceIsDownload = false;

    if (downloadEntry != null) {
      // Verify the file/URI still exists before using it.
      bool exists = false;
      try {
        if (downloadEntry.path.startsWith('content://')) {
          // MediaStore URI — verified asynchronously.
          exists = true; // optimistic; error will be caught below
        } else {
          exists = await File(downloadEntry.path).exists();
        }
      } catch (_) {}

      if (exists) {
        localPath        = downloadEntry.path;
        sourceIsDownload = true;
      } else {
        // File is gone — remove from index and fall through to streaming.
        debugPrint('[AudioPlayer] downloaded file missing for ${song.id}, '
            'removing from index');
        unawaited(DownloadIndexService.instance.remove(song.id));
      }
    }

    // After an await, check if we've been superseded.
    if (_loadSerial != mySerial) return;

    final isRemoteSource = localPath == null;
    final attemptedUrls = Set<String>.from(failedStreamUrls);
    String? activeStreamUrl;

    try {
      if (localPath != null && !localPath.startsWith('content://')) {
        // ① Downloaded local file — play directly, no network.
        if (kDebugMode) {
          debugPrint('[AudioPlayer] ${song.id} source: download '
              '(${downloadEntry?.format ?? "???"})');
        }
        await _player.setAudioSource(
          AudioSource.file(localPath, tag: mediaItem),
          preload: true,
        ).timeout(_localSourceTimeout);
      } else if (localPath != null) {
        // ① Downloaded file via MediaStore URI (Android API 29+).
        if (kDebugMode) {
          debugPrint('[AudioPlayer] ${song.id} source: download (MediaStore)');
        }
        bool mediaStoreOk = false;
        try {
          await _player.setAudioSource(
            AudioSource.uri(Uri.parse(localPath), tag: mediaItem),
            preload: true,
          );
          mediaStoreOk = true;
        } catch (uriErr) {
          debugPrint('[AudioPlayer] MediaStore URI failed for ${song.id}: $uriErr');
          final connectivity = await Connectivity().checkConnectivity();
          final canReachNetwork = connectivity.any(
            (result) => result != ConnectivityResult.none,
          );
          if (!canReachNetwork) rethrow;
        }

        if (!mediaStoreOk) {
          // If the local URI cannot be opened while connected, recover by
          // resolving a remote source. Offline playback never enters this path.
          if (_loadSerial != mySerial) return;
          final loaded =
              await _openRemoteSource(song, mediaItem, mySerial, attemptedUrls);
          if (_loadSerial != mySerial) return;
          if (loaded == null) {
            throw YoutubeServiceException(
              'No compatible audio stream could be opened for ${song.title}.',
            );
          }
          activeStreamUrl = loaded.streamUrl;
          _loadedFromCache = loaded.fromCache;
        }
      } else {
        // ② Private audio cache (Android) or ③ stream URL.
        final loaded = await _openRemoteSource(song, mediaItem, mySerial, attemptedUrls);
        if (_loadSerial != mySerial) return;
        if (loaded == null) {
          throw YoutubeServiceException(
            'No compatible audio stream could be opened for ${song.title}.',
          );
        }
        activeStreamUrl  = loaded.streamUrl;
        _loadedFromCache = loaded.fromCache;
      }

      _playbackErrorSub = _player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _handlePlaybackError(
            index,
            mySerial,
            isRemoteSource,
            activeStreamUrl,
            attemptedUrls,
            error,
          );
        },
      );
      if (_loadSerial == mySerial) {
        // just_audio's play future stays pending until playback pauses or ends.
        // Do not block track-change notifications and next-track prefetch on it.
        unawaited(_player.play().catchError((Object error) {
          _handlePlaybackError(
            index,
            mySerial,
            isRemoteSource,
            activeStreamUrl,
            attemptedUrls,
            error,
          );
        }));
        _watchFirstAudio(tapWatch, song.id, fromDownload: sourceIsDownload);
      }
    } catch (e) {
      if (_loadSerial == mySerial) {
        debugPrint('[AudioPlayer] tap-to-first-audio FAILED '
            'after ${tapWatch.elapsedMilliseconds} ms '
            '(source: ${_loadedFromCache ? 'cache' : 'network'}): $e');
        _errorController.add(
          e is YoutubeServiceException ? e.message : 'Playback failed: $e',
        );
      }
      return;
    }

    // Only notify / prefetch / subscribe if this load is still current.
    if (_loadSerial != mySerial) return;

    // Precache next queue item artwork.
    _maybePrecacheArtwork();

    _songChangeController.add(song);
    _prefetchUpcoming();

    _completionSub = _player.playerStateStream.listen((ps) {
      if (ps.processingState == ProcessingState.completed &&
          _loopMode != LoopMode.one) {
        skipToNext();
      }
    }, onError: (Object error, StackTrace stackTrace) {
      _handlePlaybackError(
        index,
        mySerial,
        isRemoteSource,
        activeStreamUrl,
        attemptedUrls,
        error,
      );
    });
    if (isRemoteSource) {
      _startupWatchdog = Timer(const Duration(seconds: 8), () {
        if (_loadSerial == mySerial &&
            _player.playing &&
            _player.position == Duration.zero) {
          _handlePlaybackError(
            index,
            mySerial,
            isRemoteSource,
            activeStreamUrl,
            attemptedUrls,
            TimeoutException('The audio stream did not start.'),
          );
        }
      });
    }
  }

  /// Keep the pre-shuffle order while incorporating queue additions/removals.
  /// Queue updates often contain the shuffled display order, which must not
  /// replace the order restored when shuffle is turned off.
  void _reconcileShuffleBaseline(List<Song> updatedQueue) {
    final original = _unshuffledQueue;
    if (original == null) {
      _unshuffledQueue = List<Song>.from(updatedQueue);
      return;
    }

    final byId = {for (final song in updatedQueue) song.id: song};
    final reconciled = <Song>[
      for (final song in original)
        if (byId.containsKey(song.id)) byId.remove(song.id)!,
      for (final song in updatedQueue)
        if (byId.containsKey(song.id)) byId.remove(song.id)!,
    ];
    _unshuffledQueue = reconciled;
  }

  // ── Remote source resolution (URL cache + private audio cache) ───────────

  /// Opens [song] for playback, preferring the private audio file cache.
  ///
  /// Order of attempts:
  ///   1. A complete cached file for this videoId. On a hit we play the file
  ///      directly and never touch youtube_explode_dart at all — no manifest
  ///      request, no URL resolution, no network.
  ///   2. Resolve a stream URL (URL cache first) and open it through a
  ///      [LockCachingAudioSource] that fills the private cache while it plays.
  ///
  /// Returns null when every candidate failed, or when the load was superseded
  /// (callers detect that by comparing `_loadSerial`). Never throws: the
  /// caller turns null into the user-visible error message.
  Future<_LoadedSource?> _openRemoteSource(
    Song song,
    MediaItem mediaItem,
    int mySerial,
    Set<String> attemptedUrls,
  ) async {
    // ── 1. Private audio file cache hit ──────────────────────────────────────
    if (_cacheEnabled) {
      final cachedFile = await AudioCacheService.instance.lookup(song.id);
      if (_loadSerial != mySerial) return null;
      if (cachedFile != null) {
        try {
          await _player
              .setAudioSource(
                AudioSource.file(cachedFile.path, tag: mediaItem),
                preload: true,
              )
              .timeout(_streamAttemptTimeout);
          final size = await cachedFile.length();
          debugPrint('[AudioPlayer] ${song.id} source=cache-hit '
              '(${formatCacheBytes(size)})');
          return const _LoadedSource(streamUrl: null, fromCache: true);
        } catch (error) {
          // A file we believe is complete failed to decode — almost always a
          // truncated write. Delete it and fall through to the network.
          debugPrint('[AudioPlayer] cache file unusable for ${song.id}: $error');
          unawaited(AudioCacheService.instance.delete(song.id));
        }
      }
    }

    // ── 2. Resolve a URL and stream it, filling the cache on the way ─────────
    final cachedUrl = await _youtube
        .getAudioStreamUrl(song.id)
        .timeout(_streamAttemptTimeout);
    var candidates = <String>[cachedUrl];
    var candidatesFetched = false;
    if (attemptedUrls.contains(cachedUrl)) {
      candidates
        ..clear()
        ..addAll(await _youtube
            .getAudioStreamCandidates(song.id)
            .timeout(_streamAttemptTimeout));
      candidatesFetched = true;
    }

    Object? lastError;

    Future<bool> tryUrl(String streamUrl) async {
      if (attemptedUrls.length >= _maxStreamsPerLoad) return false;
      if (!attemptedUrls.add(streamUrl)) return false;
      if (_loadSerial != mySerial) return false;
      try {
        final source = await _remoteAudioSource(
          streamUrl,
          mediaItem,
          songId: song.id,
        );
        await _player
            .setAudioSource(source, preload: true)
            .timeout(_streamAttemptTimeout);
        if (source is LockCachingAudioSource) {
          unawaited(_watchCacheFill(source, song));
        }
        return true;
      } catch (error) {
        lastError = error;
        return false;
      }
    }

    for (final streamUrl in candidates) {
      if (await tryUrl(streamUrl)) {
        _youtube.rememberAudioStreamUrl(song.id, streamUrl);
        _persistStreamUrl(song, streamUrl);
        return _LoadedSource(streamUrl: streamUrl);
      }
      if (_loadSerial != mySerial) return null;
    }

    if (!candidatesFetched && attemptedUrls.length < _maxStreamsPerLoad) {
      final alternatives = await _youtube
          .getAudioStreamCandidates(song.id)
          .timeout(_streamAttemptTimeout);
      for (final streamUrl in alternatives) {
        if (await tryUrl(streamUrl)) {
          _youtube.rememberAudioStreamUrl(song.id, streamUrl);
          _persistStreamUrl(song, streamUrl);
          return _LoadedSource(streamUrl: streamUrl);
        }
        if (_loadSerial != mySerial) return null;
      }
    }

    if (lastError != null) {
      debugPrint('[AudioPlayer] all stream candidates failed for ${song.id}: '
          '$lastError');
    }
    return null;
  }

  /// Builds the playback source for a resolved stream URL.
  ///
  /// On Android this is a [LockCachingAudioSource] pointed at the private cache
  /// path, so the track is written to disk while it plays and future plays are
  /// served locally. Everywhere else — and on any cache failure — it degrades to
  /// a plain streaming source.
  Future<AudioSource> _remoteAudioSource(
    String streamUrl,
    MediaItem mediaItem, {
    String? songId,
  }) async {
    const headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/114.0.0.0 Safari/537.36',
    };
    final uri = Uri.parse(streamUrl);

    if (_cacheEnabled && songId != null) {
      try {
        final cacheFile = await AudioCacheService.instance.fileFor(songId);
        if (cacheFile != null) {
          // LockCachingAudioSource writes to `<path>.part` and renames on
          // completion, so a partial download is never visible to lookup().
          return LockCachingAudioSource(
            uri,
            headers: headers,
            cacheFile: cacheFile,
            tag: mediaItem,
          );
        }
      } catch (e) {
        debugPrint('[AudioPlayer] cache source unavailable for $songId: $e');
      }
    }

    return AudioSource.uri(uri, tag: mediaItem, headers: headers);
  }

  /// Waits for a playback-time download to finish, records it in the LRU index
  /// and then trims the cache back under the user's limit.
  Future<void> _watchCacheFill(
      LockCachingAudioSource source, Song song) async {
    try {
      await for (final progress in source.downloadProgressStream) {
        if (progress < 1.0) continue;
        await AudioCacheService.instance.markComplete(song.id);
        await AudioCacheService.instance
            .evictIfNeeded(protect: _protectedCacheIds());
        return;
      }
    } catch (e) {
      debugPrint('[AudioCache] fill watcher ended for ${song.id}: $e');
    }
  }

  /// Ids eviction must never touch: the playing track and the next queue items.
  Set<String> _protectedCacheIds() {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return const {};
    final ids = <String>{_queue[_currentIndex].id};
    for (var offset = 1; offset <= 2; offset++) {
      ids.add(_queue[(_currentIndex + offset) % _queue.length].id);
    }
    return ids;
  }

  /// Precache the next queue item's artwork, throttled to once per track.
  void _maybePrecacheArtwork() {
    if (_queue.length <= 1 || _currentIndex < 0 || _currentIndex >= _queue.length) {
      return;
    }
    final nextSong = _queue[(_currentIndex + 1) % _queue.length];
    final url = nextSong.thumbnailUrl;
    if (url.isEmpty) return;
    if (_lastArtworkPrecached == url) return;
    _lastArtworkPrecached = url;
    try {
      // Best-effort: no BuildContext is available here.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          final element = WidgetsBinding.instance.rootElement;
          if (element == null) return;
          precacheImage(
            CachedNetworkImageProvider(
              url,
              cacheManager: ArtworkCacheManager.instance,
            ),
            element,
          );
        } catch (_) {}
      });
    } catch (_) {
      // Precaching is best-effort.
    }
  }

  /// Logs tap-to-first-audio exactly once per load, tagged with whether the
  /// audio came from a download, the private cache, or the network.
  void _watchFirstAudio(Stopwatch watch, String videoId, {bool fromDownload = false}) {
    _firstAudioSub?.cancel();
    _firstAudioSub = _player.playerStateStream.listen((ps) {
      if (!ps.playing) return;
      _firstAudioSub?.cancel();
      _firstAudioSub = null;
      if (kDebugMode) {
        final source = fromDownload
            ? 'download'
            : (_loadedFromCache ? 'cache' : 'network');
        debugPrint('[AudioPlayer] tap-to-first-audio '
            '${watch.elapsedMilliseconds} ms '
            '($videoId, source: $source)');
      }
    });
  }

  void _handlePlaybackError(
    int index,
    int serial,
    bool isRemoteSource,
    String? activeStreamUrl,
    Set<String> attemptedUrls,
    Object error,
  ) {
    if (_loadSerial != serial) return;
    if (_recoveringSerial == serial) return;

    // ── Cache corruption recovery ──────────────────────────────────────────
    // A file served from the private cache that fails to play is a bad write,
    // not a network problem. Drop it, forget the URL and reload from the
    // network exactly once. `_cacheRetryUsed` stops this from looping.
    if (_loadedFromCache && !_cacheRetryUsed && _cacheEnabled && isRemoteSource) {
      _cacheRetryUsed = true;
      _recoveringSerial = serial;
      final videoId = _queue[index].id;
      unawaited(() async {
        try {
          await AudioCacheService.instance.delete(videoId);
          _youtube.forgetStreamUrl(videoId);
        } catch (_) {
          // Cache cleanup is best-effort; the retry still goes to network.
        }
        if (_loadSerial != serial) return;
        try {
          await _loadAndPlay(index, isCacheRetry: true);
        } catch (retryError) {
          if (_loadSerial == serial) {
            _errorController.add('Playback failed: $retryError');
          }
        } finally {
          if (_recoveringSerial == serial) _recoveringSerial = null;
        }
      }());
      return;
    }

    if (!isRemoteSource || attemptedUrls.length >= _maxStreamsPerLoad) {
      _player.pause().catchError((_) {});
      _errorController.add('Playback failed: $error');
      return;
    }

    _recoveringSerial = serial;
    unawaited(() async {
      try {
        final failed = Set<String>.from(attemptedUrls);
        if (activeStreamUrl != null) failed.add(activeStreamUrl);
        if (_loadSerial != serial) return;
        await _loadAndPlay(index, failedStreamUrls: failed);
      } catch (retryError) {
        if (_loadSerial == serial) {
          _errorController.add('Playback failed: $retryError');
        }
      } finally {
        if (_recoveringSerial == serial) _recoveringSerial = null;
      }
    }());
  }


  /// Write the resolved stream URL back into the Song stored in Hive
  /// (liked_songs / recently_played) so cold starts can use it directly.
  void _persistStreamUrl(Song song, String url) {
    try {
      if (song.isInBox) {
        // Song is already a Hive object — update it in place
        final updated = song.copyWith(
          streamUrl: url,
          streamUrlFetchedAt: DateTime.now(),
        );
        song.box?.put(song.key, updated);
      }
    } catch (_) {
      // Non-critical — ignore failures silently
    }
  }

  /// Warms the next [kPrefetchDepth] queue items: stream URL first, then the
  /// audio file, in the background. Cancels whatever the previous track had
  /// scheduled.
  void _prefetchUpcoming() {
    if (_queue.length <= 1) return;
    final upcoming = <Song>[];
    final current = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex].id
        : '';
    for (var offset = 1;
        offset <= kPrefetchDepth && offset < _queue.length;
        offset++) {
      final song = _queue[(_currentIndex + offset) % _queue.length];
      if (song.id != current) upcoming.add(song);
    }
    _prefetch.schedule(upcoming, protect: {if (current.isNotEmpty) current});
  }

  void dispose() {
    _completionSub?.cancel();
    _playbackErrorSub?.cancel();
    _firstAudioSub?.cancel();
    _startupWatchdog?.cancel();
    _prefetch.dispose();
    _errorController.close();
    _songChangeController.close();
    _player.dispose();
    _youtube.dispose();
  }
}

// ─── Result of _openRemoteSource ───────────────────────────────────────────

class _LoadedSource {
  /// The URL that was opened, or null when playback came from a cached file.
  final String? streamUrl;

  /// True when the bytes came from the private audio file cache.
  final bool fromCache;

  const _LoadedSource({this.streamUrl, this.fromCache = false});
}
