// desktop/home/desktop_yt_album_view.dart
// Shows a YouTube Music album fetched by browseId.
// Parses the track list and plays through the existing player.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ytmusic_models.dart';
import '../../providers/player_provider.dart';
import '../../services/ytmusic_service.dart';
import '../../widgets/artist_link.dart';
import '../shell/desktop_navigation.dart';
import '../theme/desktop_theme.dart';

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final _ytAlbumTracksProvider =
    FutureProvider.autoDispose.family<AlbumTracksData, String>(
  (ref, browseId) => YtMusicService.instance.getAlbumTracks(browseId),
);

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class DesktopYtAlbumView extends ConsumerWidget {
  final String browseId;

  const DesktopYtAlbumView({super.key, required this.browseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final async = ref.watch(_ytAlbumTracksProvider(browseId));

    return Container(
      decoration: BoxDecoration(
        color: theme.panelSurfaceColor,
        borderRadius: BorderRadius.all(
          Radius.circular(theme.layout.panelRadius),
        ),
      ),
      child: async.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: theme.button),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48, color: theme.subtext),
              const SizedBox(height: 16),
              Text('Could not load album',
                  style: TextStyle(color: theme.text, fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(e.toString(),
                  style: TextStyle(color: theme.subtext, fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
        data: (data) => _AlbumBody(data: data),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Album body
// ---------------------------------------------------------------------------

class _AlbumBody extends ConsumerWidget {
  final AlbumTracksData data;

  const _AlbumBody({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final player = ref.watch(playerProvider);

    return CustomScrollView(
      slivers: [
        // ── Header ────────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Cover art
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: data.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: data.coverUrl,
                          width: 180,
                          height: 180,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _artPlaceholder(theme),
                        )
                      : _artPlaceholder(theme),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.title.isNotEmpty ? data.title : 'Album',
                        style: TextStyle(
                          color: theme.text,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (data.artist.isNotEmpty)
                            Flexible(
                              child: data.artistBrowseId != null
                                  ? MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () => ref
                                            .read(desktopYtArtistRequestProvider
                                                .notifier)
                                            .state = data.artistBrowseId,
                                        child: Text(
                                          data.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: theme.text,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Text(
                                      data.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: theme.subtext, fontSize: 13),
                                    ),
                            ),
                          if (data.artist.isNotEmpty) const SizedBox(width: 6),
                          Text(
                            [
                              if (data.year.isNotEmpty) data.year,
                              '${data.tracks.length} song${data.tracks.length == 1 ? '' : 's'}',
                            ].join(' • '),
                            style:
                                TextStyle(color: theme.subtext, fontSize: 13),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (data.tracks.isNotEmpty)
                        ElevatedButton.icon(
                          onPressed: () => _playFrom(ref, 0),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play all'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.button,
                            foregroundColor: theme.onButtonFill,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(child: Container(height: 1, color: theme.shadow)),

        // ── Track list ────────────────────────────────────────────────────
        if (data.tracks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text('No tracks found',
                    style: TextStyle(color: theme.subtext)),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _TrackRow(
                index: i + 1,
                song: data.tracks[i],
                isPlaying:
                    player.currentSong?.id == data.tracks[i].videoId,
                onTap: () => _playFrom(ref, i),
              ),
              childCount: data.tracks.length,
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _artPlaceholder(AppThemeData theme) => Container(
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.album, size: 64, color: theme.subtext),
      );

  void _playFrom(WidgetRef ref, int index) {
    final songs = data.tracks.map((t) => t.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(
          songs[index],
          queue: songs,
        );
  }
}

// ---------------------------------------------------------------------------
// Track row
// ---------------------------------------------------------------------------

class _TrackRow extends StatefulWidget {
  final int index;
  final YtSong song;
  final bool isPlaying;
  final VoidCallback onTap;

  const _TrackRow({
    required this.index,
    required this.song,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color:
              _hovered ? theme.highlightElevated : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              // Track number / playing indicator
              SizedBox(
                width: 28,
                child: widget.isPlaying
                    ? Icon(Icons.equalizer, size: 18, color: theme.button)
                    : Text(
                        '${widget.index}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: theme.subtext, fontSize: 13),
                      ),
              ),
              const SizedBox(width: 14),
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: widget.song.coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.song.coverUrl,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _thumbPlaceholder(theme),
                      )
                    : _thumbPlaceholder(theme),
              ),
              const SizedBox(width: 12),
              // Title + artist
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.isPlaying ? theme.button : theme.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.song.artist.isNotEmpty)
                      ArtistNames(
                        refs: widget.song.artistRefs,
                        fallbackName: widget.song.artist,
                        maxLines: 1,
                        style:
                            TextStyle(color: theme.subtext, fontSize: 11),
                        hoverStyle: TextStyle(
                            color: theme.text,
                            fontSize: 11,
                            decoration: TextDecoration.underline,
                            decorationColor: theme.text),
                      ),
                  ],
                ),
              ),
              // Duration
              if (widget.song.duration != Duration.zero)
                Text(
                  _fmt(widget.song.duration),
                  style: TextStyle(color: theme.subtext, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbPlaceholder(AppThemeData theme) => Container(
        width: 40,
        height: 40,
        color: theme.card,
        child:
            Icon(Icons.music_note, size: 18, color: theme.subtext),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
