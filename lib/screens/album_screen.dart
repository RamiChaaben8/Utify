// ============================================================
// screens/album_screen.dart — mobile album page
//
// Shows a YouTube Music album fetched by browseId: cover, title, artist
// (tappable), track list. Tapping a track plays through the existing player.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ytmusic_models.dart';
import '../providers/player_provider.dart';
import '../services/artwork_cache_manager.dart';
import '../services/ytmusic_service.dart';
import '../widgets/artist_link.dart';
import 'artist_screen.dart';
import 'now_playing_screen.dart';

final _albumTracksProvider =
    FutureProvider.autoDispose.family<AlbumTracksData, String>(
  (ref, browseId) => YtMusicService.instance.getAlbumTracks(browseId),
);

class AlbumScreen extends ConsumerWidget {
  final String browseId;

  const AlbumScreen({super.key, required this.browseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_albumTracksProvider(browseId));

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF1DB954)),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined,
                      size: 48, color: Color(0xFF555555)),
                  const SizedBox(height: 12),
                  const Text('Could not load album',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(e.toString(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFF8A8A8A), fontSize: 12)),
                ],
              ),
            ),
          ),
          data: (data) => _AlbumBody(data: data),
        ),
      ),
    );
  }
}

class _AlbumBody extends ConsumerWidget {
  final AlbumTracksData data;

  const _AlbumBody({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingId = ref.watch(playerProvider.select((s) => s.currentSong?.id));

    return CustomScrollView(
      slivers: [
        // ── Header ────────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: data.coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: data.coverUrl,
                        cacheManager: ArtworkCacheManager.instance,
                        width: 180,
                        height: 180,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _coverPlaceholder(),
                      )
                    : _coverPlaceholder(),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  data.title.isNotEmpty ? data.title : 'Album',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (data.artist.isNotEmpty)
                    Flexible(
                      child: GestureDetector(
                        onTap: data.artistBrowseId == null
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ArtistScreen(
                                        browseId: data.artistBrowseId!),
                                  ),
                                ),
                        child: Text(
                          data.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: data.artistBrowseId != null
                                ? Colors.white
                                : const Color(0xFFB3B3B3),
                            fontSize: 13,
                            fontWeight: data.artistBrowseId != null
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  if (data.artist.isNotEmpty) const SizedBox(width: 6),
                  Text(
                    [
                      if (data.year.isNotEmpty) data.year,
                      '${data.tracks.length} song${data.tracks.length == 1 ? '' : 's'}',
                    ].join(' • '),
                    style: const TextStyle(
                        color: Color(0xFFB3B3B3), fontSize: 13),
                  ),
                ],
              ),
              if (data.tracks.isNotEmpty) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _playFrom(context, ref, 0),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play all'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 12),
                    shape: const StadiumBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),

        // ── Tracks ────────────────────────────────────────────────────────
        if (data.tracks.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text('No tracks found',
                    style: TextStyle(color: Color(0xFFB3B3B3))),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _TrackRow(
                index: i + 1,
                song: data.tracks[i],
                isPlaying: playingId == data.tracks[i].videoId,
                onTap: () => _playFrom(context, ref, i),
              ),
              childCount: data.tracks.length,
            ),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _coverPlaceholder() => Container(
        width: 180,
        height: 180,
        color: const Color(0xFF1A1A1A),
        child: const Icon(Icons.album, size: 64, color: Color(0xFF555555)),
      );

  void _playFrom(BuildContext context, WidgetRef ref, int index) {
    final songs = data.tracks.map((t) => t.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(songs[index], queue: songs);
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(
                  parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: isPlaying
                  ? const Icon(Icons.equalizer,
                      size: 16, color: Color(0xFF1DB954))
                  : Text(
                      '$index',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: Color(0xFF8A8A8A), fontSize: 13),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isPlaying ? const Color(0xFF1DB954) : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (song.artist.isNotEmpty)
                    ArtistNames(
                      refs: song.artistRefs,
                      fallbackName: song.artist,
                      maxLines: 1,
                      style: const TextStyle(
                          color: Color(0xFF8A8A8A), fontSize: 12),
                      hoverStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (song.duration != Duration.zero)
              Text(
                _fmt(song.duration),
                style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
