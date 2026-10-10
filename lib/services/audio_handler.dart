// ============================================================
// services/audio_handler.dart
//
// Bridges audio_service (OS media buttons / notification) with
// the app's AudioPlayerService.
//
// Media button routing
// ─────────────────────────────────────────────────────────────
// OS media buttons (lock-screen, headset, BT remote) call the
// BaseAudioHandler overrides (play, pause, skipToNext, …).
// These MUST go through PlayerNotifier so that:
//   • Every action triggers a remote-command write via _sendCommand
//
// To avoid a circular dependency (handler → notifier → handler),
// we use a late-bound callback set: [onPlay], [onPause], etc.
// PlayerNotifier sets these after construction.
// ============================================================

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import 'audio_player_service.dart';

class TuneifyAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayerService _service;
  final List<StreamSubscription> _subs = [];
  int _lastPositionSecond = -1;

  AudioPlayerService get service => _service;

  // ── Media-button callbacks set by PlayerNotifier ──────────────────────────
  // These route OS button presses through the notifier so remote-command
  // writes are handled correctly.
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onStop;
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  Future<void> Function(Duration)? onSeek;
  Future<void> Function()? onToggleLike;

  TuneifyAudioHandler(this._service) {
    _subs.add(_service.playerStateStream.listen(_onPlayerState));

    _subs.add(_service.positionStream.listen((pos) {
      // OS media sessions only display whole seconds; publishing every audio
      // backend tick creates needless platform-channel and notification work.
      if (pos.inSeconds == _lastPositionSecond) return;
      _lastPositionSecond = pos.inSeconds;
      playbackState.add(playbackState.value.copyWith(updatePosition: pos));
    }));

    _subs.add(_service.durationStream.listen((dur) {
      if (dur == null) return;
      final item = mediaItem.value;
      if (item != null) mediaItem.add(item.copyWith(duration: dur));
    }));

    _subs.add(_service.currentIndexStream.listen((_) {
      updateCurrentSong();
    }));

    _pushPlaybackState(
      playing: false,
      processingState: AudioProcessingState.idle,
    );
  }

  void _onPlayerState(PlayerState ps) {
    _pushPlaybackState(
      playing: ps.playing,
      processingState: _mapProcessingState(ps.processingState),
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState ps) {
    switch (ps) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  void _pushPlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    final idx = _service.currentIndex;
    final liked = _isCurrentSongLiked();

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.custom(
          androidIcon:
              liked ? 'drawable/ic_favorite' : 'drawable/ic_favorite_border',
          label: liked ? 'Unlike' : 'Like',
          name: 'toggleLike',
        ),
        const MediaControl(
          androidIcon: 'drawable/ic_skip_previous',
          label: 'Previous',
          action: MediaAction.skipToPrevious,
        ),
        if (playing)
          const MediaControl(
            androidIcon: 'drawable/ic_pause',
            label: 'Pause',
            action: MediaAction.pause,
          )
        else
          const MediaControl(
            androidIcon: 'drawable/ic_play_arrow',
            label: 'Play',
            action: MediaAction.play,
          ),
        const MediaControl(
          androidIcon: 'drawable/ic_skip_next',
          label: 'Next',
          action: MediaAction.skipToNext,
        ),
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 2, 3],
      processingState: processingState,
      playing: playing,
      updatePosition: _service.player.position,
      bufferedPosition: _service.player.bufferedPosition,
      speed: _service.player.speed,
      queueIndex: idx >= 0 ? idx : null,
    ));
  }

  void updateCurrentSong() {
    final queue = _service.queue;
    final idx = _service.currentIndex;
    if (idx < 0 || idx >= queue.length) return;

    final current = queue[idx];
    final next = idx + 1 < queue.length ? queue[idx + 1] : null;
    final liked = _isCurrentSongLiked();
    final duration = _service.player.duration ??
        mediaItem.value?.duration ??
        (current.duration == Duration.zero ? null : current.duration);

    final item = MediaItem(
      id: current.id,
      title: current.title,
      artist: current.channelName,
      album: 'Tuneify',
      displaySubtitle: next != null ? 'Next: ${next.title}' : null,
      artUri: current.thumbnailUrl.isNotEmpty
          ? Uri.parse(current.thumbnailUrl)
          : null,
      duration: duration,
      extras: next != null
          ? {
              'nextSongId': next.id,
              'nextSongTitle': next.title,
              'nextSongArtist': next.channelName,
              'nextSongArt': next.thumbnailUrl,
              'liked': liked,
            }
          : null,
    );

    mediaItem.add(item);

    this.queue.add(queue
        .map((s) => MediaItem(
              id: s.id,
              title: s.title,
              artist: s.channelName,
              artUri:
                  s.thumbnailUrl.isNotEmpty ? Uri.parse(s.thumbnailUrl) : null,
            ))
        .toList());
  }

  bool _isCurrentSongLiked() {
    final id = _service.currentSong?.id;
    if (id == null || !Hive.isBoxOpen('liked_songs')) return false;
    return Hive.box<Song>('liked_songs').containsKey(id);
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name != 'toggleLike') return null;
    if (onToggleLike != null) {
      await onToggleLike!();
    }
    _pushPlaybackState(
      playing: _service.player.playing,
      processingState: _mapProcessingState(_service.player.processingState),
    );
    return true;
  }

  Song? get nextSong {
    final q = _service.queue;
    final idx = _service.currentIndex;
    if (q.length <= 1 || idx < 0) return null;
    return q[(idx + 1) % q.length];
  }

  // ── BaseAudioHandler overrides (OS media buttons) ─────────────────────────
  // Always route through PlayerNotifier callbacks when set.
  // The callbacks are wired by PlayerNotifier immediately after construction,
  // so the fallback path (direct _service call) only executes during the very
  // brief window between audio_service init and ProviderScope setup —
  // i.e. before there is any song to play anyway.
  //
  // IMPORTANT: do NOT call _service.play/skipToNext/etc. as the fallback
  // because that bypasses remote-command writes in PlayerNotifier.
  // We simply no-op when callbacks are not yet wired, which is safe because
  // no music is loaded at that point.

  @override
  Future<void> play() async {
    if (onPlay != null) {
      await onPlay!();
    }
    // No fallback — media buttons before the notifier is wired are no-ops.
  }

  @override
  Future<void> pause() async {
    if (onPause != null) {
      await onPause!();
    } else {
      // Safe to pause directly — pausing never causes state divergence.
      await _service.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (onSeek != null) {
      await onSeek!(position);
    } else {
      await _service.seek(position);
    }
    _lastPositionSecond = position.inSeconds;
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  @override
  Future<void> skipToNext() async {
    if (onSkipToNext != null) {
      await onSkipToNext!();
    }
    // No fallback — skip before notifier is wired is a no-op.
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipToPrevious != null) {
      await onSkipToPrevious!();
    }
    // No fallback — skip before notifier is wired is a no-op.
  }

  @override
  Future<void> stop() async {
    await (onStop?.call() ?? _service.stop());
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final q = _service.queue;
    if (index < 0 || index >= q.length) return;
    await _service.playSong(q[index], queue: q);
  }

  void disposeHandler() {
    for (final s in _subs) s.cancel();
  }
}
