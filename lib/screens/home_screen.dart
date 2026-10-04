// ============================================================
// screens/home_screen.dart
//
// Spotify / YT-Music style home feed:
//   • Time-of-day greeting header
//   • Quick-play chips (recently played, 2-column grid)
//   • Dynamic feed sections: Recommended, Trending, Your Taste,
//     New Releases, Chill Mix, Hip-Hop, Pop Hits
//
// Sections arrive one-by-one as their YouTube searches complete.
// Each section shows a shimmer skeleton while loading.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';

import '../models/song.dart';
import '../models/ytmusic_models.dart';
import '../providers/ytmusic_home_provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/guest_session_provider.dart';
import 'now_playing_screen.dart';
import '../widgets/app_thumbnail.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/listen_party_controls.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final isGuest = ref.watch(guestSessionProvider);
    final library = ref.watch(libraryProvider);
    final recent = library.recentlyPlayed;

    // Collect all sections as generic (label, title, songs) tuples for mobile
    final sections = <({String label, String title, List<YtSong> songs})>[
      if (feed.effectiveQuickPicks.isNotEmpty)
        (label: 'QUICK PICKS', title: 'Songs you might like', songs: feed.effectiveQuickPicks),
      if (feed.mixedForYou.isNotEmpty)
        (label: 'MIXED FOR YOU', title: 'A blend of your favorites', songs: feed.mixedForYou),
      if (feed.becauseYouListenedTo.isNotEmpty)
        (label: 'BECAUSE YOU LISTENED TO', title: feed.becauseArtistName ?? 'Your top artist', songs: feed.becauseYouListenedTo),
      if (feed.trending.isNotEmpty)
        (label: 'TRENDING', title: "What's hot right now", songs: feed.trending),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: RefreshIndicator(
          color: const Color(0xFF1DB954),
          backgroundColor: const Color(0xFF1A1A1A),
          onRefresh: () => ref.read(homeFeedProvider.notifier).refresh(),
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── Greeting header ──────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 20, 8),
                  child: Row(
                    children: [
                      const ProfileAvatar(),
                      const Spacer(),
                      if (!isGuest) const PartyInviteButton(),
                    ],
                  ),
                ),
              ),

              // ── Quick-play grid (recently played) ────────────────────────
              if (recent.isNotEmpty)
                SliverToBoxAdapter(
                  child: _QuickPlayGrid(
                    songs: recent.take(6).toList(),
                    onTap: (song) {
                      if (ref.read(playerProvider).currentSong?.id == song.id) {
                        _openPlayer(context);
                      } else {
                        ref
                            .read(playerProvider.notifier)
                            .playSong(song, queue: recent);
                        _openPlayer(context);
                      }
                    },
                  ),
                ),

              // ── Dynamic feed sections ────────────────────────────────────
              if (feed.isLoading)
                SliverToBoxAdapter(child: _buildFullSkeleton())
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final sec = sections[i];
                      return _SectionRow(
                        label: sec.label,
                        title: sec.title,
                        songs: sec.songs,
                        onSongTap: (song) {
                          ref.read(playerProvider.notifier).playSong(song);
                          _openPlayer(context);
                        },
                      );
                    },
                    childCount: sections.length,
                  ),
                ),

              // Bottom padding for mini-player + nav bar
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

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

  Widget _buildFullSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(
        3,
        (_) => Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: _SectionSkeleton(),
        ),
      ),
    );
  }
}

// ─── Quick-play 2-column grid ─────────────────────────────────────────────────

class _QuickPlayGrid extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song) onTap;

  const _QuickPlayGrid({required this.songs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recently Played',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 4.5,
            ),
            itemCount: songs.length,
            itemBuilder: (_, i) => _QuickPlayChip(
              song: songs[i],
              onTap: () => onTap(songs[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickPlayChip extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _QuickPlayChip({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            // Thumbnail
            AppThumbnail(
              imageUrl: song.thumbnailUrl,
              videoId: song.id,
              width: 48,
              height: 48,
              borderRadius: 6,
              backgroundColor: const Color(0xFF282828),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                song.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

// ─── Section row ─────────────────────────────────────────────────────────────

class _SectionRow extends StatelessWidget {
  final String label;
  final String title;
  final List<YtSong> songs;
  final void Function(Song) onSongTap;

  const _SectionRow({
    required this.label,
    required this.title,
    required this.songs,
    required this.onSongTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFB3B3B3),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF1DB954),
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),

          // Cards
          if (songs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Nothing found right now',
                style: TextStyle(color: Color(0xFF555555), fontSize: 13),
              ),
            )
          else
            SizedBox(
              height: 192,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                primary: false,
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: songs.length,
                itemBuilder: (_, i) {
                  final ytSong = songs[i];
                  return _SongCard(
                    song: ytSong.toSong(),
                    onTap: () => onSongTap(ytSong.toSong()),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Song card ────────────────────────────────────────────────────────────────

class _SongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _SongCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            AppThumbnail(
              imageUrl: song.thumbnailUrl,
              videoId: song.id,
              width: 140,
              height: 140,
              borderRadius: 10,
              backgroundColor: const Color(0xFF1A1A1A),
            ),
            const SizedBox(height: 6),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              song.channelName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shimmer skeleton ─────────────────────────────────────────────────────────

class _SectionSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: Shimmer.fromColors(
        baseColor: const Color(0xFF1A1A1A),
        highlightColor: const Color(0xFF2A2A2A),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: 5,
          itemBuilder: (_, __) => Container(
            width: 140,
            margin: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 6),
                Container(width: 100, height: 10, color: Colors.white),
                const SizedBox(height: 4),
                Container(width: 70, height: 8, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
