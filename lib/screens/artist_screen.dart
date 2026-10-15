// ============================================================
// screens/artist_screen.dart — mobile artist page
//
// Header (image, name, subscribers, description), top songs, albums,
// singles and related artists. Tapping a song plays through the existing
// player; tapping an album/artist pushes the matching screen.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ytmusic_models.dart';
import '../providers/player_provider.dart';
import '../providers/ytmusic_home_provider.dart';
import '../services/artwork_cache_manager.dart';
import 'album_screen.dart';
import 'now_playing_screen.dart';

class ArtistScreen extends ConsumerWidget {
  final String browseId;

  const ArtistScreen({super.key, required this.browseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(artistProvider(browseId));

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF1DB954)),
          ),
          error: (e, _) => _ErrorState(message: e.toString()),
          data: (data) => _ArtistBody(data: data),
        ),
      ),
    );
  }
}

class _ArtistBody extends ConsumerWidget {
  final YtArtistData data;

  const _ArtistBody({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAnything = data.topSongs.isNotEmpty ||
        data.albums.isNotEmpty ||
        data.singles.isNotEmpty ||
        data.relatedArtists.isNotEmpty;

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
              ClipOval(
                child: data.pictureUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: data.pictureUrl,
                        cacheManager: ArtworkCacheManager.instance,
                        width: 140,
                        height: 140,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _avatarPlaceholder(),
                      )
                    : _avatarPlaceholder(),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  data.name.isNotEmpty ? data.name : 'Artist',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (data.subscribers.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  data.subscribers,
                  style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
                ),
              ],
              if (data.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    data.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Color(0xFF8A8A8A), fontSize: 12, height: 1.4),
                  ),
                ),
              ],
              if (data.topSongs.isNotEmpty) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _playAll(context, ref),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
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

        if (!hasAnything)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text('No songs or albums found',
                    style: TextStyle(color: Color(0xFFB3B3B3))),
              ),
            ),
          ),

        // ── Top songs ─────────────────────────────────────────────────────
        if (data.topSongs.isNotEmpty)
          const SliverToBoxAdapter(
            child: _Label('Popular'),
          ),
        if (data.topSongs.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _SongTile(
                song: data.topSongs[i],
                onTap: () => _playFrom(context, ref, i),
              ),
              childCount: data.topSongs.length,
            ),
          ),

        // ── Albums ────────────────────────────────────────────────────────
        if (data.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: _AlbumRow(label: 'Albums', albums: data.albums),
          ),

        // ── Singles ───────────────────────────────────────────────────────
        if (data.singles.isNotEmpty)
          SliverToBoxAdapter(
            child: _AlbumRow(label: 'Singles', albums: data.singles),
          ),

        // ── Related artists ───────────────────────────────────────────────
        if (data.relatedArtists.isNotEmpty)
          SliverToBoxAdapter(
            child: _ArtistRow(artists: data.relatedArtists),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _avatarPlaceholder() => Container(
        width: 140,
        height: 140,
        color: const Color(0xFF1A1A1A),
        child: const Icon(Icons.person, size: 60, color: Color(0xFF555555)),
      );

  void _openPlayer(BuildContext context) {
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

  void _playAll(BuildContext context, WidgetRef ref) {
    final songs = data.topSongs.map((s) => s.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(songs.first, queue: songs);
    _openPlayer(context);
  }

  void _playFrom(BuildContext context, WidgetRef ref, int index) {
    final songs = data.topSongs.map((s) => s.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(songs[index], queue: songs);
    _openPlayer(context);
  }
}

// ─── Shared bits ──────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Color(0xFFB3B3B3),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final YtSong song;
  final VoidCallback onTap;

  const _SongTile({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: song.coverUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: song.coverUrl,
                      cacheManager: ArtworkCacheManager.instance,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _songPlaceholder(),
                    )
                  : _songPlaceholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
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

  Widget _songPlaceholder() => Container(
        width: 48,
        height: 48,
        color: const Color(0xFF1A1A1A),
        child: const Icon(Icons.music_note, size: 20, color: Color(0xFF555555)),
      );
}

class _AlbumRow extends StatelessWidget {
  final String label;
  final List<YtAlbum> albums;

  const _AlbumRow({required this.label, required this.albums});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            itemBuilder: (ctx, i) {
              final a = albums[i];
              return GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AlbumScreen(browseId: a.browseId),
                )),
                child: Container(
                  width: 130,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: a.coverUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: a.coverUrl,
                                cacheManager: ArtworkCacheManager.instance,
                                width: 130,
                                height: 130,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    _albumPlaceholder(),
                              )
                            : _albumPlaceholder(),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        a.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [a.typeLabel, if (a.year != null) '${a.year}']
                            .join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xFF8A8A8A), fontSize: 11),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _albumPlaceholder() => Container(
        width: 130,
        height: 130,
        color: const Color(0xFF1A1A1A),
        child: const Icon(Icons.album, size: 40, color: Color(0xFF555555)),
      );
}

class _ArtistRow extends StatelessWidget {
  final List<YtArtist> artists;

  const _ArtistRow({required this.artists});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('Fans might also like'),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.length,
            itemBuilder: (ctx, i) {
              final a = artists[i];
              return GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArtistScreen(browseId: a.browseId),
                )),
                child: Container(
                  width: 120,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    children: [
                      ClipOval(
                        child: a.pictureUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: a.pictureUrl,
                                cacheManager: ArtworkCacheManager.instance,
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    _artistPlaceholder(),
                              )
                            : _artistPlaceholder(),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        a.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _artistPlaceholder() => Container(
        width: 120,
        height: 120,
        color: const Color(0xFF1A1A1A),
        child: const Icon(Icons.person, size: 48, color: Color(0xFF555555)),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 48, color: Color(0xFF555555)),
            const SizedBox(height: 12),
            const Text('Could not load artist',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
