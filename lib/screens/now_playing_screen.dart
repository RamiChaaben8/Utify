// ============================================================
// screens/now_playing_screen.dart  — Spotify-style mobile player
//
// Layout (scrollable):
//   ┌─────────────────────────────────────────────┐
//   │  Full-screen video background (looping)     │  ← page 1
//   │  ── overlaid at bottom:                     │
//   │     current lyric line                      │
//   │     song info + like btn + seekbar          │
//   │     controls (shuffle/prev/play/next/repeat)│
//   │     device + queue + share row              │
//   └─────────────────────────────────────────────┘
//   ┌─────────────────────────────────────────────┐
//   │  Lyrics panel (dark card, scrollable)       │  ← page 2
//   │  language selector btn                      │
//   │  all lyrics lines                           │
//   └─────────────────────────────────────────────┘
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../models/song.dart';
import '../models/playlist.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../providers/lyrics_provider.dart';
import '../widgets/seek_bar.dart';
import '../screens/queue_screen.dart';
import '../providers/download_provider.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/video_preview_widget.dart';
import '../widgets/device_picker.dart';
import '../widgets/listen_party_controls.dart';
import '../services/artwork_cache_manager.dart';
import '../services/youtube_service.dart';

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  final ScrollController _scroll = ScrollController();
  String? _lastVideoId;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final sourcePlaylist = ref.watch(playerProvider.select((s) => s.sourcePlaylist));
    final lyrics = ref.watch(lyricsProvider);

    if (song == null) {
      return const Scaffold(body: Center(child: Text('Nothing playing')));
    }

    // Trigger lyrics fetch when song changes
    if (!song.isLocal && song.id != _lastVideoId) {
      _lastVideoId = song.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(lyricsProvider.notifier).fetchFor(song.id, song: song);
      });
    }

    final screenH = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Full-screen video (or album art) background ─────────────
          Positioned.fill(
            child: song.isLocal || song.thumbnailUrl.isEmpty
                ? const _AlbumPlaceholder()
                : VideoPreviewWidget(
                    imageUrl: song.thumbnailUrl,
                    fit: BoxFit.cover,
                  ),
          ),

          // ── Dark gradient overlay (bottom-heavy) ────────────────────
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.35, 0.65, 1.0],
                  colors: [
                    Color(0x55000000),
                    Color(0x00000000),
                    Color(0xAA000000),
                    Color(0xFF000000),
                  ],
                ),
              ),
            ),
          ),

          // ── Scrollable content ──────────────────────────────────────
          SafeArea(
            top: false,
            child: SingleChildScrollView(
              controller: _scroll,
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  // ── Page 1: controls over video ─────────────────────
                  SizedBox(
                    height: screenH,
                    child: _PlayerPage(
                      lyrics: lyrics,
                      song: song,
                    ),
                  ),

                  // ── Page 2: lyrics panel ─────────────────────────────
                  _LyricsPage(lyrics: lyrics),
                ],
              ),
            ),
          ),

          // ── Top bar (always on top) ─────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _TopBar(
                song: song,
                sourcePlaylist: sourcePlaylist,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final Song song;
  final Playlist? sourcePlaylist;

  const _TopBar({
    required this.song,
    required this.sourcePlaylist,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                size: 32, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  sourcePlaylist == null
                      ? 'Playing from Queue'
                      : 'Playing from Playlist',
                  style: const TextStyle(
                    color: Color(0xFFB3B3B3),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (sourcePlaylist != null)
                  Text(
                    sourcePlaylist!.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 24),
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: const Color(0xFF1A1A1A),
              builder: (_) => _SongActionsSheet(
                song: song,
                sourcePlaylist: sourcePlaylist,
                pageContext: context,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SongActionsSheet extends ConsumerWidget {
  final Song song;
  final Playlist? sourcePlaylist;
  final BuildContext pageContext;

  const _SongActionsSheet({
    required this.song,
    required this.sourcePlaylist,
    required this.pageContext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.playlist_add, color: Colors.white),
            title: const Text('Add to playlist'),
            onTap: () {
              Navigator.pop(context);
              showModalBottomSheet(
                context: pageContext,
                backgroundColor: const Color(0xFF1A1A1A),
                builder: (_) => AddToPlaylistSheet(song: song),
              );
            },
          ),
          if (sourcePlaylist != null)
            ListTile(
              leading: const Icon(Icons.playlist_remove, color: Colors.white),
              title: Text('Remove from ${sourcePlaylist!.name}'),
              onTap: () async {
                Navigator.pop(context);
                await ref
                    .read(libraryProvider.notifier)
                    .removeSongFromPlaylistObj(sourcePlaylist!, song.id);
              },
            ),
          ListTile(
            leading: const Icon(Icons.queue_music, color: Colors.white),
            title: const Text('Add to queue'),
            onTap: () {
              ref.read(playerProvider.notifier).addToQueue(song);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_play_next, color: Colors.white),
            title: const Text('Go to queue'),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(pageContext).push(
                MaterialPageRoute(builder: (_) => const QueueScreen()),
              );
            },
          ),
          if (!song.isLocal) ...[
            Builder(builder: (ctx) {
              final (isDownloaded, isDownloading) = ref.watch(downloadProvider.select((s) => (
                    s.isDownloaded(song.id),
                    s.isDownloading(song.id),
                  )));
              
              if (isDownloaded) {
                return ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Delete downloaded file', style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(downloadProvider.notifier).deleteSong(song.id);
                  },
                );
              } else if (isDownloading) {
                return ListTile(
                  leading: const Icon(Icons.cancel_outlined, color: Colors.orange),
                  title: const Text('Cancel download', style: TextStyle(color: Colors.orange)),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(downloadProvider.notifier).cancelDownload(song.id);
                  },
                );
              } else {
                return ListTile(
                  leading: const Icon(Icons.download_outlined, color: Color(0xFF1DB954)),
                  title: const Text('Download', style: TextStyle(color: Color(0xFF1DB954))),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(downloadProvider.notifier).downloadSong(song);
                  },
                );
              }
            }),
          ],
        ],
      ),
    );
  }
}

// ─── Page 1: player controls on top of video ──────────────────────────────────

class _PlayerPage extends ConsumerWidget {
  final LyricsState lyrics;
  final Song song;

  const _PlayerPage({
    required this.lyrics,
    required this.song,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final isLiked = library.isLiked(song.id);
    final shuffle = ref.watch(playerProvider.select((s) => s.shuffle));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final isLoading = ref.watch(playerProvider.select((s) => s.isLoading));
    final loopMode = ref.watch(playerProvider.select((s) => s.loopMode));
    final error = ref.watch(playerProvider.select((s) => s.error));

    return Column(
      children: [
        // Spacer to push controls to bottom half
        const Expanded(flex: 3, child: SizedBox.shrink()),

        // ── Current lyric line ─────────────────────────────────────
        _CurrentLyricLine(lyrics: lyrics),

        // ── Song info + like ───────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(
            children: [
              // Album art thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: song.thumbnailUrl,
                  cacheManager: ArtworkCacheManager.instance,
                  memCacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
                  memCacheHeight: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                      color: const Color(0xFF282828), width: 56, height: 56),
                  errorWidget: (_, __, ___) => Container(
                      color: const Color(0xFF282828),
                      width: 56,
                      height: 56,
                      child: const Icon(Icons.music_note,
                          color: Color(0xFF3A3A3A))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      song.channelName,
                      style: const TextStyle(
                          color: Color(0xFFB3B3B3), fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Like button
              IconButton(
                icon: Icon(
                  isLiked ? Icons.check_circle : Icons.check_circle_outline,
                  color: isLiked ? const Color(0xFF1DB954) : Colors.white,
                  size: 28,
                ),
                onPressed: () async {
                  try {
                    await ref.read(libraryProvider.notifier).toggleLike(song);
                  } catch (_) {}
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── Seek bar ───────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: _NowPlayingSeekBar(),
        ),

        const SizedBox(height: 4),

        // ── Main controls ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(
                  Icons.shuffle,
                  color: shuffle
                      ? const Color(0xFF1DB954)
                      : const Color(0xFFB3B3B3),
                  size: 22,
                ),
                onPressed: () =>
                    ref.read(playerProvider.notifier).toggleShuffle(),
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous,
                    color: Colors.white, size: 36),
                onPressed: () =>
                    ref.read(playerProvider.notifier).skipToPrevious(),
              ),
              _PlayPauseButton(
                isPlaying: isPlaying,
                isLoading: isLoading,
                onPressed: () =>
                    ref.read(playerProvider.notifier).togglePlayPause(),
              ),
              IconButton(
                icon:
                    const Icon(Icons.skip_next, color: Colors.white, size: 36),
                onPressed: () => ref.read(playerProvider.notifier).skipToNext(),
              ),
              IconButton(
                icon: Icon(
                  loopMode == LoopMode.one
                      ? Icons.repeat_one
                      : Icons.repeat,
                  color: loopMode != LoopMode.off
                      ? const Color(0xFF1DB954)
                      : const Color(0xFFB3B3B3),
                  size: 22,
                ),
                onPressed: () =>
                    ref.read(playerProvider.notifier).toggleLoopMode(),
              ),
            ],
          ),
        ),

        const SizedBox(height: 4),

        // ── Device / share / queue row ─────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const DevicePickerButton(size: 20),
              const ListenPartyControls(showLabel: false),
              const Spacer(),
              if (!song.isLocal) _DownloadButton(song: song),
              IconButton(
                icon: const Icon(Icons.queue_music_outlined,
                    color: Color(0xFFB3B3B3), size: 22),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const QueueScreen()),
                ),
              ),
            ],
          ),
        ),

        // Error display
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(error,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red, size: 16),
                    onPressed: () =>
                        ref.read(playerProvider.notifier).clearError(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CurrentLyricLine extends ConsumerWidget {
  final LyricsState lyrics;
  const _CurrentLyricLine({required this.lyrics});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!lyrics.hasLyrics) return const SizedBox.shrink();

    final pos = ref.watch(playerProvider.select((s) => s.position));
    LyricLine? active;
    for (final line in lyrics.lines) {
      if (pos >= line.start) active = line;
    }
    final currentLine = active?.text;

    if (currentLine == null || currentLine.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Text(
        currentLine,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          height: 1.3,
          shadows: [
            Shadow(
              color: Colors.black,
              blurRadius: 8,
            ),
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _NowPlayingSeekBar extends ConsumerWidget {
  const _NowPlayingSeekBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerProvider.select((s) => s.position));
    final duration = ref.watch(playerProvider.select((s) => s.duration));

    return SeekBar(
      position: position,
      duration: duration,
      onSeek: (pos) => ref.read(playerProvider.notifier).seek(pos),
    );
  }
}

class _DownloadButton extends ConsumerWidget {
  final Song song;

  const _DownloadButton({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (isDownloaded, isDownloading, progressStep) =
        ref.watch(downloadProvider.select((s) => (
              s.isDownloaded(song.id),
              s.isDownloading(song.id),
              (s.progressFor(song.id) * 20).round(), // 5% steps
            )));
    final progress = progressStep / 20.0;

    if (isDownloading) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 2.5,
                color: const Color(0xFF1DB954),
                backgroundColor: Colors.white12,
              ),
            ),
            Text(
              progress > 0 ? '${(progress * 100).round()}%' : '…',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 7,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return IconButton(
      icon: Icon(
        isDownloaded ? Icons.download_done : Icons.download_outlined,
        color: isDownloaded ? const Color(0xFF1DB954) : const Color(0xFFB3B3B3),
        size: 22,
      ),
      onPressed: isDownloaded
          ? null
          : () => ref.read(downloadProvider.notifier).downloadSong(song),
    );
  }
}

// ─── Page 2: full lyrics panel ────────────────────────────────────────────────

class _LyricsPage extends ConsumerWidget {
  final LyricsState lyrics;
  const _LyricsPage({required this.lyrics});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerProvider.select((s) => s.position));
    return Container(
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Lyrics card ────────────────────────────────────────────
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: BoxDecoration(
              color: const Color(0xFF8B1A1A), // Spotify's dark red lyrics card
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
                  child: Row(
                    children: [
                      const Text(
                        'Lyrics preview',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // Language selector — only shown when multiple tracks
                      if (lyrics.availableTracks.length > 1)
                        _TrackSelectorButton(lyrics: lyrics),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Lyrics lines
                if (lyrics.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF1DB954),
                        strokeWidth: 2,
                      ),
                    ),
                  )
                else if (!lyrics.hasLyrics)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    child: Text(
                      lyrics.error ?? 'No lyrics available for this song.',
                      style: const TextStyle(
                          color: Color(0xFFCCCCCC), fontSize: 14),
                    ),
                  )
                else
                  _LyricsBody(
                    lyrics: lyrics,
                    position: position,
                  ),

                // Show lyrics button
                if (lyrics.hasLyrics)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: GestureDetector(
                      onTap: () => _showFullLyrics(context, lyrics),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Show lyrics',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFullLyrics(BuildContext context, LyricsState lyrics) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF8B1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (ctx, scroll) => Consumer(
          builder: (context, ref, _) {
            final position = ref.watch(playerProvider.select((s) => s.position));
            return Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Lyrics',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Directionality(
                    textDirection:
                        lyrics.isArabic ? TextDirection.rtl : TextDirection.ltr,
                    child: ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: lyrics.lines.length,
                      itemBuilder: (_, i) {
                        final line = lyrics.lines[i];
                        final isActive = position >= line.start &&
                            (i == lyrics.lines.length - 1 ||
                                position < lyrics.lines[i + 1].start);
                        return _MobileLyricLine(
                          line: line,
                          isActive: isActive,
                          isPast: i < _activeLineIndex(lyrics, position),
                          position: position,
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ─── Lyrics body (preview in card) ───────────────────────────────────────────

class _LyricsBody extends StatelessWidget {
  final LyricsState lyrics;
  final Duration position;
  const _LyricsBody({required this.lyrics, required this.position});

  @override
  Widget build(BuildContext context) {
    // Show up to 6 lines around the current position
    final lines = lyrics.lines;
    final activeIdx = _activeLyricIndex(lines, position);

    final start = (activeIdx - 1).clamp(0, lines.length);
    final end = (activeIdx + 5).clamp(0, lines.length);
    final preview = lines.sublist(start, end);

    return Directionality(
      textDirection: lyrics.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: preview.asMap().entries.map((e) {
            final globalIdx = start + e.key;
            final isActive = globalIdx == activeIdx;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _MobileLyricLine(
                line: e.value,
                isActive: isActive,
                isPast: globalIdx < activeIdx,
                position: position,
                compact: true,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

}

int _activeLineIndex(LyricsState lyrics, Duration position) {
  return _activeLyricIndex(lyrics.lines, position);
}

int _activeLyricIndex(List<LyricLine> lines, Duration position) {
  var low = 0;
  var high = lines.length - 1;
  var active = 0;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (position >= lines[middle].start) {
      active = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return active;
}

class _MobileLyricLine extends ConsumerWidget {
  final LyricLine line;
  final bool isActive;
  final bool isPast;
  final Duration position;
  final bool compact;

  const _MobileLyricLine({
    required this.line,
    required this.isActive,
    required this.isPast,
    required this.position,
    this.compact = false,
  });

  void _seek(WidgetRef ref) {
    if (line.start == Duration.zero) return;
    ref.read(playerProvider.notifier).seek(line.start);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final fontSize = compact ? (isActive ? 17.0 : 15.0) : 18.0;
    final isSynced = line.start != Duration.zero;

    if (isActive && line.hasWordTiming) {
      return GestureDetector(
        onTap: () => _seek(ref),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Align(
            alignment: rtl ? Alignment.centerRight : Alignment.centerLeft,
            child: Wrap(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              spacing: 0,
              runSpacing: 2,
              children: line.words.map((word) {
                final lit = position >= word.start;
                return AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 120),
                  style: TextStyle(
                    color: lit ? const Color(0xFF1DB954) : Colors.white54,
                    fontSize: fontSize,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  child: Text('${word.text} '),
                );
              }).toList(),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: isSynced ? () => _seek(ref) : null,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Align(
          alignment: rtl ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            style: TextStyle(
              color: isActive
                  ? Colors.white
                  : isPast
                      ? Colors.white38
                      : Colors.white60,
              fontSize: fontSize,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              height: 1.4,
            ),
            child: Text(
              line.text,
              textAlign: rtl ? TextAlign.right : TextAlign.left,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Track selector button ────────────────────────────────────────────────────

class _TrackSelectorButton extends ConsumerWidget {
  final LyricsState lyrics;
  const _TrackSelectorButton({required this.lyrics});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedLabel = lyrics.selectedTrackLabel ??
        (lyrics.availableTracks.isNotEmpty
            ? lyrics.availableTracks.first.label
            : 'Auto');
    final shortLabel = selectedLabel
        .replaceAll(' (auto-generated)', '')
        .replaceAll(' (auto)', '');

    return GestureDetector(
      onTapDown: (d) => _showMenu(context, ref, d.globalPosition),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.subtitles_outlined,
                color: Colors.white70, size: 13),
            const SizedBox(width: 4),
            Text(
              shortLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref, Offset position) {
    final items = lyrics.availableTracks.map((track) {
      final isSelected = track.code == lyrics.selectedTrackCode;
      return PopupMenuItem<String>(
        value: track.code,
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: isSelected
                  ? const Icon(Icons.check, color: Color(0xFF1DB954), size: 14)
                  : null,
            ),
            const SizedBox(width: 4),
            Text(
              track.label
                  .replaceAll(' (auto-generated)', '')
                  .replaceAll(' (auto)', ''),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      );
    }).toList();

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx - 160,
        position.dy,
        position.dx,
        position.dy + 40,
      ),
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: items,
    ).then((code) {
      if (code != null) {
        ref.read(lyricsProvider.notifier).selectTrack(code);
      }
    });
  }
}

// ─── Play/Pause button ─────────────────────────────────────────────────────────

class _PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;

  const _PlayPauseButton({
    required this.isPlaying,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: isLoading
            ? const Padding(
                padding: EdgeInsets.all(18),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.black,
                ),
              )
            : Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.black,
                size: 36,
              ),
      ),
    );
  }
}

// ─── Album art placeholder ─────────────────────────────────────────────────────

class _AlbumPlaceholder extends StatelessWidget {
  const _AlbumPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: const Center(
        child: Icon(Icons.music_note, size: 80, color: Color(0xFF3A3A3A)),
      ),
    );
  }
}
