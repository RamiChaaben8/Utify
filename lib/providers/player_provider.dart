// ============================================================
// providers/player_provider.dart
//
// Central playback state provider.
//
// Active-device model (Spotify-style)
// ─────────────────────────────────────────────────────────────
// • Only the ACTIVE device loads audio and executes commands.
// • Passive devices: show a device-picker banner; tap "Listen
//   here" to become active.
// • A device becomes active by calling claimAsActiveDevice().
// • On first app open with no active device, this device
//   auto-claims (becomes active).
// • On second open when another device is already active, this
//   device stays passive — no audio load, no loop.
//
// Key rules
// ─────────────────────────────────────────────────────────────
// • All transport calls go to _service, never _handler.
//   Handler callbacks (onPlay/onPause/…) are OS-button routing:
//   OS → handler override → notifier method → service.
// • _sendCommand() only fires from explicit user actions.
// • _applyingRemote flag prevents songChangeStream from echoing
//   remote-triggered loads back to Firestore.
// ============================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import '../models/playlist.dart';
import '../models/download_index.dart';
import '../services/audio_handler.dart';
import '../services/audio_player_service.dart';
import '../services/youtube_service.dart';
import '../services/sync_service.dart';
import '../services/firestore_service.dart';
import '../platform/permissions.dart';
import 'library_provider.dart';
import 'sync_provider.dart';

// ─── State class ─────────────────────────────────────────────────────────────

class PlayerState {
  final Song? currentSong;
  final bool isPlaying;
  final bool isLoading;
  final String? error;
  final Duration position;
  final Duration duration;
  final List<Song> queue;
  final int currentIndex;
  final Playlist? sourcePlaylist;
  final bool shuffle;
  final LoopMode loopMode;

  /// Non-null while another device's command is visible in the banner.
  final RemoteCommandDoc? remoteCommand;

  /// The currently active device (null = no one active yet).
  final ActiveDeviceDoc? activeDevice;

  /// Whether THIS device is the active playback device.
  final bool isActiveDevice;

  const PlayerState({
    this.currentSong,
    this.isPlaying = false,
    this.isLoading = false,
    this.error,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentIndex = -1,
    this.sourcePlaylist,
    this.shuffle = false,
    this.loopMode = LoopMode.off,
    this.remoteCommand,
    this.activeDevice,
    this.isActiveDevice = false,
  });

  PlayerState copyWith({
    Song? currentSong,
    bool? isPlaying,
    bool? isLoading,
    String? error,
    Duration? position,
    Duration? duration,
    List<Song>? queue,
    int? currentIndex,
    Playlist? sourcePlaylist,
    bool? shuffle,
    LoopMode? loopMode,
    RemoteCommandDoc? remoteCommand,
    ActiveDeviceDoc? activeDevice,
    bool? isActiveDevice,
    bool clearSong = false,
    bool clearError = false,
    bool clearRemote = false,
    bool clearActiveDevice = false,
    bool clearSourcePlaylist = false,
  }) {
    return PlayerState(
      currentSong: clearSong ? null : (currentSong ?? this.currentSong),
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      sourcePlaylist:
          clearSourcePlaylist ? null : (sourcePlaylist ?? this.sourcePlaylist),
      shuffle: shuffle ?? this.shuffle,
      loopMode: loopMode ?? this.loopMode,
      remoteCommand: clearRemote ? null : (remoteCommand ?? this.remoteCommand),
      activeDevice:
          clearActiveDevice ? null : (activeDevice ?? this.activeDevice),
      isActiveDevice: isActiveDevice ?? this.isActiveDevice,
    );
  }
}

// ─── Notifier ────────────────────────────────────────────────────────────────

class PlayerNotifier extends StateNotifier<PlayerState> {
  final TuneifyAudioHandler _handler;
  final LibraryNotifier _library;
  final SyncNotifier _sync;

  AudioPlayerService get _service => _handler.service;

  final List<StreamSubscription> _subs = [];
  DateTime _lastPositionSync = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastPositionBucket = -1;

  /// True while a remote-triggered load is in progress.
  bool _applyingRemote = false;

  PlayerNotifier(this._handler, this._library, this._sync)
      : super(const PlayerState()) {
    _subscribeToPlayerStreams();
    _subscribeToRemoteCommands();
    _subscribeToActiveDevice();
    // Wire OS media-button callbacks.
    _handler.onPlay = () => play();
    _handler.onPause = () => pause();
    _handler.onStop = () => stop();
    _handler.onSkipToNext = () => skipToNext();
    _handler.onSkipToPrevious = () => skipToPrevious();
    _handler.onSeek = (pos) => seek(pos);
    _handler.onToggleLike = _toggleCurrentSongLike;
  }

  Future<void> _toggleCurrentSongLike() async {
    final song = state.currentSong ?? _service.currentSong;
    if (song == null) return;
    await _library.toggleLike(song);
  }

  // ── Internal stream subscriptions ────────────────────────────────────────

  void _subscribeToPlayerStreams() {
    _subs.add(_service.positionStream.listen((pos) {
      // The progress UI does not need every backend position event. Coalesce
      // updates to ~2.5 per second so screens and lyric widgets do less work.
      final positionBucket = pos.inMilliseconds ~/ 400;
      if ((_sync.service.isActive || _service.player.playing) &&
          positionBucket != _lastPositionBucket) {
        _lastPositionBucket = positionBucket;
        state = state.copyWith(position: pos);
      }
      if (_sync.service.isActive &&
          state.currentSong != null &&
          _sync.service.hasOtherDevices &&
          DateTime.now().difference(_lastPositionSync) >=
              const Duration(seconds: 45)) {
        _lastPositionSync = DateTime.now();
        _sendCommand(RemoteCommand.none);
      }
    }));

    _subs.add(_service.durationStream.listen((dur) {
      if (dur != null) state = state.copyWith(duration: dur);
    }));

    _subs.add(_service.playerStateStream.listen((ps) {
      // Loading is set explicitly while a track is being loaded. Do not turn
      // it back on merely because a paused player reports buffering; this is
      // common after restoring a saved session on Android and desktop.
      final loadFinished = ps.playing ||
          ps.processingState == ProcessingState.ready ||
          ps.processingState == ProcessingState.completed;
      state = state.copyWith(
        isPlaying: ps.playing,
        isLoading: loadFinished ? false : state.isLoading,
      );
    }));

    _subs.add(_service.errorStream.listen((msg) {
      state = state.copyWith(isLoading: false, error: msg);
    }));

    _subs.add(_service.songChangeStream.listen((song) {
      state = state.copyWith(
        currentSong: song,
        currentIndex: _service.currentIndex,
        queue: _service.queue,
        isLoading: false,
        // _loadAndPlay starts the track before emitting songChangeStream.
        // Do not overwrite that playing state and make the first pause tap
        // appear to be a second play action.
        isPlaying: true,
        clearError: true,
      );
      _handler.updateCurrentSong();

      if (!_applyingRemote) {
        _library.addToRecentlyPlayed(song).catchError((_) {});
        _sendCommand(RemoteCommand.playSong);
      }
    }));
  }

  void _subscribeToRemoteCommands() {
    _subs.add(_sync.service.remoteCommandStream.listen(_onRemoteCommand));
  }

  void _subscribeToActiveDevice() {
    _subs.add(_sync.service.activeDeviceStream.listen((doc) {
      final isActive = doc?.deviceId == _sync.service.deviceId;
      state = state.copyWith(activeDevice: doc, isActiveDevice: isActive);
    }));
  }

  // ── Remote command handler ────────────────────────────────────────────────
  // Active device  → EXECUTES the command (plays/pauses local audio).
  // Passive device → OBSERVES only (updates UI state, never touches local audio).

  void _onRemoteCommand(RemoteCommandDoc doc) {
    state = state.copyWith(remoteCommand: doc);

    // SyncService updates this flag before publishing the active-device
    // stream. Use it as the source of truth so a command arriving during
    // stream/UI startup is still handled by the actual active device.
    if (_sync.service.isActive) {
      // ── Active device: execute ──────────────────────────────────────────
      switch (doc.command) {
        case RemoteCommand.play:
          if (state.currentSong != null) {
            _service.play().catchError((_) {});
            state = state.copyWith(isPlaying: true);
          } else if (doc.currentSong != null) {
            _applyRemotePlaySong(doc);
          }
        case RemoteCommand.pause:
          _service.pause().catchError((_) {});
          state = state.copyWith(isPlaying: false);
        case RemoteCommand.next:
          _applyRemoteSkip(skipForward: true, doc: doc);
        case RemoteCommand.prev:
          _applyRemoteSkip(skipForward: false, doc: doc);
        case RemoteCommand.playSong:
          _applyRemotePlaySong(doc);
        case RemoteCommand.queueUpdate:
          _service.setQueue(doc.queue, currentIndex: doc.queueIndex);
          state = state.copyWith(
            queue: doc.queue,
            currentIndex: doc.queueIndex,
          );
        case RemoteCommand.seek:
          _service
              .seek(Duration(milliseconds: doc.positionMs))
              .catchError((_) {});
          state = state.copyWith(
            position: Duration(milliseconds: doc.positionMs),
          );
        case RemoteCommand.none:
          break;
      }
    } else {
      // ── Passive device: observe (UI sync only, no local audio) ──────────
      switch (doc.command) {
        case RemoteCommand.playSong:
          final song = doc.currentSong;
          if (song != null) {
            state = state.copyWith(
              currentSong: song,
              queue: doc.queue.isNotEmpty ? doc.queue : state.queue,
              currentIndex: doc.queueIndex,
              position: Duration(milliseconds: doc.positionMs),
              duration: song.duration,
              isLoading: false,
              isPlaying: doc.isPlaying,
              clearError: true,
            );
          }
        case RemoteCommand.queueUpdate:
          state = state.copyWith(
            queue: doc.queue,
            currentIndex: doc.queueIndex,
          );
        case RemoteCommand.play:
          state = state.copyWith(isPlaying: true, isLoading: false);
        case RemoteCommand.pause:
          state = state.copyWith(isPlaying: false, isLoading: false);
        case RemoteCommand.seek:
          state = state.copyWith(
            position: Duration(milliseconds: doc.positionMs),
          );
        case RemoteCommand.next:
        case RemoteCommand.prev:
          // The active device will fire a playSong command once the song loads.
          state = state.copyWith(isLoading: true);
        case RemoteCommand.none:
          state = state.copyWith(
            position: Duration(milliseconds: doc.positionMs),
            isPlaying: doc.isPlaying,
            isLoading: false,
          );
          break;
      }
    }
  }

  void _applyRemoteSkip(
      {required bool skipForward, required RemoteCommandDoc doc}) {
    _applyingRemote = true;
    final fut = skipForward ? _service.skipToNext() : _service.skipToPrevious();
    fut
        .then((_) {
          if (!mounted) return;
          _updateFromService();
          _handler.updateCurrentSong();
          if (_service.currentSong != null) {
            _sendCommand(RemoteCommand.playSong);
          }
        })
        .catchError((_) {})
        .whenComplete(() => _applyingRemote = false);
  }

  void _applyRemotePlaySong(RemoteCommandDoc doc) {
    final song = doc.currentSong;
    if (song == null) return;

    _applyingRemote = true;
    state = state.copyWith(
      currentSong: song,
      isLoading: true,
      isPlaying: false,
      clearError: true,
    );

    _service.playSong(song, queue: doc.queue).then((_) {
      if (!mounted) return;
      final position = Duration(milliseconds: doc.positionMs);
      _service.seek(position).catchError((_) {});
      _updateFromService();
      state = state.copyWith(
        position: position,
        duration: song.duration,
        isPlaying: doc.isPlaying,
      );
      if (!doc.isPlaying) _service.pause().catchError((_) {});
      _handler.updateCurrentSong();
    }).catchError((e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: e is YoutubeServiceException ? e.message : 'Playback failed: $e',
      );
    }).whenComplete(() => _applyingRemote = false);
  }

  void _updateFromService() {
    state = state.copyWith(
      currentSong: _service.currentSong,
      queue: _service.queue,
      currentIndex: _service.currentIndex,
      isLoading: false,
    );
  }

  // ── Sync helper ───────────────────────────────────────────────────────────

  void _sendCommand(RemoteCommand command) {
    _sync.service
        .sendCommand(
          command: command,
          currentSong: state.currentSong,
          queue: state.queue,
          queueIndex: state.currentIndex,
          positionMs: state.position.inMilliseconds,
          isPlaying: state.isPlaying,
        )
        .catchError((_) {});
  }

  // ── Active device management ──────────────────────────────────────────────

  /// Called by DevicePickerSheet when user taps "Listen here".
  /// Claims this device as active and loads whatever is currently queued.
  Future<void> listenHere() async {
    await _sync.service.claimAsActiveDevice();
    state = state.copyWith(isActiveDevice: true);

    // If we already have a song in state (populated by _onRemoteCommand
    // while passive), load it directly — no Firestore round-trip needed.
    final current = state.currentSong;
    if (current != null) {
      _applyingRemote = true;
      state =
          state.copyWith(isLoading: true, isPlaying: false, clearError: true);
      try {
        await _service.playSong(current, queue: state.queue);
        await _service.pause();
        if (!mounted) return;
        state = state.copyWith(
          currentSong: _service.currentSong ?? current,
          queue: _service.queue,
          currentIndex: _service.currentIndex,
          isLoading: false,
          isPlaying: false,
        );
        _handler.updateCurrentSong();
      } catch (_) {
        if (mounted) state = state.copyWith(isLoading: false);
      } finally {
        _applyingRemote = false;
      }
      return;
    }

    // Nothing in state yet — fall back to the last saved Firestore session.
    await restoreLastSession();
  }

  /// Transfer active playback to [targetDeviceId].
  /// Pauses local audio, makes the target device active in Firestore, then
  /// sends the current queue so the target device auto-starts playback.
  Future<void> transferToDevice(
      String targetDeviceId, String targetDeviceName) async {
    // Pause local playback first.
    final wasPlaying = state.isPlaying;
    await _service.pause();
    state = state.copyWith(isPlaying: wasPlaying, isActiveDevice: false);

    // Make the other device active in Firestore.
    await _sync.service.transferToDevice(targetDeviceId, targetDeviceName);

    // Send the current queue/song to the target via a playSong command
    // so it can start playing immediately.
    if (state.currentSong != null) {
      _sendCommand(RemoteCommand.playSong);
    }
  }

  /// Called after login. Only runs if this device is the active device.
  Future<void> restoreCachedSession(String uid) async {
    final doc = await _sync.service.getCachedLastStateForUser(uid);
    if (doc != null) {
      _applyRestoredState(doc, loadAudio: false);
    }
  }

  Future<void> restoreLastSession() async {
    try {
      final cached = await _sync.service.getCachedLastState();
      if (cached != null) {
        _applyRestoredState(cached, loadAudio: false);
      }

      final doc = await _sync.service.getLastState();
      if (doc == null) return;
      if (!mounted) return;

      // Every device restores the queue metadata so its UI is current.
      // Only the active device loads audio.
      if (!_sync.service.isActive) {
        state = state.copyWith(
          currentSong: doc.currentSong,
          queue: doc.queue,
          currentIndex: doc.queueIndex,
          position: Duration(milliseconds: doc.positionMs),
          duration: doc.currentSong?.duration ?? Duration.zero,
          isLoading: false,
          isPlaying: doc.isPlaying,
          clearError: true,
        );
        return;
      }

      final song = doc.currentSong;
      if (song == null) {
        state = state.copyWith(
          queue: doc.queue,
          currentIndex: doc.queueIndex,
          position: Duration(milliseconds: doc.positionMs),
          duration: Duration.zero,
          isLoading: false,
          isPlaying: doc.isPlaying,
          clearError: true,
        );
        return;
      }

      _applyingRemote = true;
      state = state.copyWith(
        currentSong: song,
        position: Duration(milliseconds: doc.positionMs),
        isLoading: true,
        isPlaying: doc.isPlaying,
        clearError: true,
      );

      await _service.playSong(song, queue: doc.queue);
      await _service.seek(Duration(milliseconds: doc.positionMs));
      if (!doc.isPlaying) await _service.pause();

      if (!mounted) {
        _applyingRemote = false;
        return;
      }

      state = state.copyWith(
        currentSong: _service.currentSong ?? song,
        queue: _service.queue,
        currentIndex: _service.currentIndex,
        position: Duration(milliseconds: doc.positionMs),
        isLoading: false,
        isPlaying: doc.isPlaying,
      );
      _handler.updateCurrentSong();
    } catch (_) {
      if (mounted) state = state.copyWith(isLoading: false);
    } finally {
      _applyingRemote = false;
    }
  }

  void _applyRestoredState(
    RemoteCommandDoc doc, {
    required bool loadAudio,
  }) {
    if (!mounted) return;
    state = state.copyWith(
      currentSong: doc.currentSong,
      queue: doc.queue,
      currentIndex: doc.queueIndex,
      position: Duration(milliseconds: doc.positionMs),
      duration: doc.currentSong?.duration ?? Duration.zero,
      isLoading: loadAudio,
      isPlaying: doc.isPlaying,
      clearError: true,
    );
  }

  // ── Dismiss banner ────────────────────────────────────────────────────────

  void dismissRemoteBanner() => state = state.copyWith(clearRemote: true);

  // ── Playback ─────────────────────────────────────────────────────────────

  void playSong(
    Song song, {
    List<Song>? queue,
    Playlist? sourcePlaylist,
    bool suppressRemoteCommand = false,
  }) {
    if (!state.isActiveDevice) {
      state = state.copyWith(isActiveDevice: true);
      unawaited(_sync.service.claimAsActiveDevice().catchError((_) {}));
    }
    unawaited(_doPlaySong(
      song,
      queue: queue,
      sourcePlaylist: sourcePlaylist,
      suppressRemoteCommand: suppressRemoteCommand,
    ));
  }

  /// Play a song from the local download index.
  /// Builds a minimal Song from the DownloadIndexEntry and plays it.
  /// The audio player will resolve the local file via DownloadIndexService.
  void playSongFromDownload(
    DownloadIndexEntry entry, {
    List<Song>? queue,
  }) {
    final song = Song(
      id: entry.videoId,
      title: entry.title.isNotEmpty ? entry.title : entry.videoId,
      channelName: entry.artist,
      thumbnailUrl: entry.thumbnailPath.isNotEmpty
          ? entry.thumbnailPath
          : 'https://i.ytimg.com/vi/${entry.videoId}/hqdefault.jpg',
      duration: Duration(milliseconds: entry.durationMs),
      isLocal: true,
    );
    playSong(song, queue: queue);
  }

  Future<void> _doPlaySong(
    Song song, {
    List<Song>? queue,
    Playlist? sourcePlaylist,
    bool suppressRemoteCommand = false,
  }) async {
    await requestNotificationPermission();
    state = state.copyWith(
      currentSong: song,
      isLoading: true,
      isPlaying: false,
      clearError: true,
      clearRemote: true,
      sourcePlaylist: sourcePlaylist,
      clearSourcePlaylist: sourcePlaylist == null,
    );

    _service.playSong(song, queue: queue).then((_) {
      if (!mounted) return;
      state = state.copyWith(
        currentSong: _service.currentSong,
        queue: _service.queue,
        currentIndex: _service.currentIndex,
        isLoading: false,
      );
      _handler.updateCurrentSong();
      _library.addToRecentlyPlayed(song).catchError((_) {});
      if (!suppressRemoteCommand) {
        _sendCommand(RemoteCommand.playSong);
      }
    }).catchError((e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: e is YoutubeServiceException ? e.message : 'Playback failed: $e',
      );
    });
  }

  Future<void> play() async {
    if (_sync.service.isActive) {
      await requestNotificationPermission();
      await _service.play();
      state = state.copyWith(isPlaying: true);
      _handler.updateCurrentSong();
    } else {
      // Passive: optimistically update UI, real update comes via observe path.
      state = state.copyWith(isPlaying: true);
    }
    _sendCommand(RemoteCommand.play);
  }

  Future<void> pause() async {
    if (_sync.service.isActive) {
      await _service.pause();
      state = state.copyWith(isPlaying: false);
    } else {
      // Passive: optimistically update UI.
      state = state.copyWith(isPlaying: false);
    }
    _sendCommand(RemoteCommand.pause);
  }

  /// Pause locally without broadcasting a remote command.
  /// Used when the app goes to background / is closed so we don't
  /// accidentally pause playback on other active devices.
  Future<void> pauseLocal() async {
    await _service.pause();
    if (mounted) state = state.copyWith(isPlaying: false);
  }

  Future<void> stop() async {
    if (_sync.service.isActive) {
      await _service.stop();
    }
    if (mounted) {
      state = state.copyWith(isPlaying: false, position: Duration.zero);
    }
  }

  /// Save the queue and current song for the next app session.
  Future<void> saveSession() {
    return _sync.service.savePlaybackState(
      currentSong: state.currentSong,
      queue: state.queue,
      queueIndex: state.currentIndex,
      positionMs: state.position.inMilliseconds,
      isPlaying: state.isPlaying,
    );
  }

  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    if (_sync.service.isActive) {
      await _service.seek(position);
    }
    state = state.copyWith(position: position);
    _sendCommand(RemoteCommand.seek);
  }

  Future<void> skipToNext() async {
    if (_sync.service.isActive) {
      state = state.copyWith(isLoading: true, clearError: true);
      try {
        await _service.skipToNext();
        state = state.copyWith(
          currentSong: _service.currentSong,
          queue: _service.queue,
          currentIndex: _service.currentIndex,
          isLoading: false,
        );
        _handler.updateCurrentSong();
        if (_service.currentSong != null) {
          _library
              .addToRecentlyPlayed(_service.currentSong!)
              .catchError((_) {});
        }
      } catch (error) {
        state =
            state.copyWith(isLoading: false, error: 'Could not skip: $error');
      }
    } else {
      // Passive: show loading spinner; real song update comes via playSong observe.
      state = state.copyWith(isLoading: true, clearError: true);
    }
    _sendCommand(RemoteCommand.next);
  }

  Future<void> skipToPrevious() async {
    if (_sync.service.isActive) {
      state = state.copyWith(isLoading: true, clearError: true);
      try {
        await _service.skipToPrevious();
        state = state.copyWith(
          currentSong: _service.currentSong,
          queue: _service.queue,
          currentIndex: _service.currentIndex,
          isLoading: false,
        );
        _handler.updateCurrentSong();
      } catch (error) {
        state =
            state.copyWith(isLoading: false, error: 'Could not skip: $error');
      }
    } else {
      state = state.copyWith(isLoading: true, clearError: true);
    }
    _sendCommand(RemoteCommand.prev);
  }

  void addToQueue(Song song) {
    final queue = List<Song>.from(state.queue);
    if (queue.any((item) => item.id == song.id)) return;
    queue.add(song);
    _updateQueue(queue);
  }

  void playNext(Song song) {
    final queue = List<Song>.from(state.queue)
      ..removeWhere((item) => item.id == song.id);
    final insertAt = (state.currentIndex + 1).clamp(0, queue.length);
    queue.insert(insertAt, song);
    _updateQueue(queue);
  }

  void removeFromQueue(int index) {
    final queue = List<Song>.from(state.queue);
    if (index < 0 || index >= queue.length || index == state.currentIndex) {
      return;
    }
    queue.removeAt(index);
    final currentIndex = index < state.currentIndex
        ? state.currentIndex - 1
        : state.currentIndex;
    _updateQueue(queue, currentIndex: currentIndex);
  }

  void reorderQueue(int oldIndex, int newIndex) {
    final queue = List<Song>.from(state.queue);
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    if (oldIndex < newIndex) newIndex--;
    final song = queue.removeAt(oldIndex);
    newIndex = newIndex.clamp(0, queue.length);
    queue.insert(newIndex, song);

    var currentIndex = state.currentIndex;
    if (oldIndex == currentIndex) {
      currentIndex = newIndex;
    } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
      currentIndex--;
    } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
      currentIndex++;
    }
    _updateQueue(queue, currentIndex: currentIndex);
  }

  void _updateQueue(List<Song> queue, {int? currentIndex}) {
    final index = currentIndex ?? state.currentIndex;
    state = state.copyWith(queue: queue, currentIndex: index);
    if (_sync.service.isActive) {
      _service.setQueue(queue, currentIndex: index);
    }
    _sendCommand(RemoteCommand.queueUpdate);
  }

  void toggleShuffle() {
    _service.toggleShuffle();
    state = state.copyWith(
      shuffle: _service.shuffle,
      queue: _service.queue,
      currentIndex: _service.currentIndex,
    );
    if (_sync.service.isActive) {
      _sendCommand(RemoteCommand.queueUpdate);
    }
  }

  Future<void> restoreGuestSession() async {
    final doc = await _sync.service.getCachedGuestLastState();
    if (doc != null) _applyRestoredState(doc, loadAudio: false);
  }

  void toggleLoopMode() {
    _service.toggleLoopMode();
    state = state.copyWith(loopMode: _service.loopMode);
  }

  void clearError() => state = state.copyWith(clearError: true);

  Song? get nextSong {
    final q = state.queue;
    final idx = state.currentIndex;
    if (q.length <= 1 || idx < 0) return null;
    return q[(idx + 1) % q.length];
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _handler.onPlay = null;
    _handler.onPause = null;
    _handler.onStop = null;
    _handler.onSkipToNext = null;
    _handler.onSkipToPrevious = null;
    _handler.onSeek = null;
    super.dispose();
  }
}

// ─── Providers ───────────────────────────────────────────────────────────────

final audioHandlerProvider = Provider<TuneifyAudioHandler>((ref) {
  throw UnimplementedError('audioHandlerProvider must be overridden in main()');
});

final playerProvider =
    StateNotifierProvider<PlayerNotifier, PlayerState>((ref) {
  return PlayerNotifier(
    ref.watch(audioHandlerProvider),
    ref.watch(libraryProvider.notifier),
    ref.watch(syncProvider.notifier),
  );
});
