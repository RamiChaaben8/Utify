// ============================================================
// screens/search_screen.dart  — Spotify-style mobile search
//
// Layout:
//   • Profile avatar + "Search" title header
//   • Large white rounded search box — triggers YouTube search on
//     submit (or debounced after 600ms idle typing)
//   • When idle: "Browse categories" grid (Music, Podcasts, etc.)
//   • When results exist: YouTube video result cards
// ============================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/song.dart';
import '../providers/youtube_provider.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../widgets/error_banner.dart';
import '../screens/now_playing_screen.dart';
import '../providers/search_history_provider.dart';
import '../widgets/profile_avatar.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty) {
      ref.read(searchProvider.notifier).clear();
      return;
    }
    // Debounce: fire after 600ms idle
    _debounce = Timer(const Duration(milliseconds: 600), () {
      _doSearch(q, false);
    });
  }

  void _doSearch([String? overrideQuery, bool unfocus = true]) {
    final query = overrideQuery ?? _controller.text.trim();
    if (query.isEmpty) return;
    if (overrideQuery != null) _controller.text = overrideQuery;
    if (unfocus) _focusNode.unfocus();
    ref.read(searchHistoryProvider.notifier).addQuery(query);
    ref.read(searchProvider.notifier).search(query);
  }

  void _clearSearch() {
    _controller.clear();
    ref.read(searchProvider.notifier).clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final currentPlayingId = ref.watch(playerProvider.select((s) => s.currentSong?.id));
    final isPlayerPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final hasQuery =
        _controller.text.trim().isNotEmpty || searchState.results.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ── Header ──────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const ProfileAvatar(),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Search',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Search box ───────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w500),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _doSearch(),
                    decoration: InputDecoration(
                      hintText: 'What do you want to listen to?',
                      hintStyle: const TextStyle(
                          color: Color(0xFF666666), fontSize: 15),
                      prefixIcon: const Icon(Icons.search,
                          color: Colors.black, size: 22),
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close,
                                  color: Colors.black, size: 20),
                              onPressed: _clearSearch,
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Error banner ─────────────────────────────────────────────
            if (searchState.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ErrorBanner(message: searchState.error!),
                ),
              ),

            // ── Loading bar ──────────────────────────────────────────────
            if (searchState.isLoading)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: Color(0xFF1DB954),
                  backgroundColor: Color(0xFF212121),
                ),
              ),

            // ── Results header ───────────────────────────────────────────
            if (searchState.results.isNotEmpty && !searchState.isLoading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${searchState.results.length} results',
                          style: const TextStyle(
                              color: Color(0xFFB3B3B3), fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Results / Category grid ──────────────────────────────────
            if (searchState.results.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final song = searchState.results[i];
                    final isCurrent = currentPlayingId == song.id;
                    return _VideoCard(
                      song: song,
                      isCurrentlyPlaying: isCurrent && isPlayerPlaying,
                      isSelected: isCurrent,
                      onTap: () => _playSong(song),
                    );
                  },
                  childCount: searchState.results.length,
                ),
              )
            else if (!searchState.isLoading && !hasQuery)
              SliverToBoxAdapter(
                child: _BrowseCategories(onSearch: _doSearch),
              )
            else if (!searchState.isLoading && hasQuery)
              SliverToBoxAdapter(
                child: _SearchHistoryOrEmpty(
                    query: searchState.query, onSearch: _doSearch),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  void _playSong(Song song) {
    final currentId = ref.read(playerProvider).currentSong?.id;
    if (currentId != song.id) {
      ref.read(playerProvider.notifier).playSong(song, queue: [song]);
    }
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

// ─── Browse categories grid ───────────────────────────────────────────────────

class _BrowseCategories extends ConsumerWidget {
  final void Function(String) onSearch;
  const _BrowseCategories({required this.onSearch});

  static const _categories = [
    _Category('Music', Color(0xFFE91E8C), Icons.music_note),
    _Category('Podcasts', Color(0xFF006450), Icons.podcasts),
    _Category('Live Events', Color(0xFF8D67AB), Icons.event),
    _Category('Made For You', Color(0xFFB49BC8), null),
    _Category('New Releases', Color(0xFF27856A), Icons.new_releases),
    _Category('Hip-Hop', Color(0xFF8D67AB), Icons.headphones),
    _Category('Pop', Color(0xFFE13300), Icons.star),
    _Category('K-Pop', Color(0xFF1E3264), Icons.favorite),
    _Category('Anime', Color(0xFFBA5D07), Icons.animation),
    _Category('Chill', Color(0xFF1DB954), Icons.spa),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search history
        if (history.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent searches',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(searchHistoryProvider.notifier).clearHistory(),
                  child: const Text('Clear',
                      style: TextStyle(color: Color(0xFF1DB954))),
                ),
              ],
            ),
          ),
          ...history.take(5).map((q) => ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: const Icon(Icons.history, color: Color(0xFFB3B3B3)),
                title: Text(q, style: const TextStyle(color: Colors.white)),
                onTap: () => onSearch(q),
              )),
        ],

        // Category grid
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            'Discover something new',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.7,
            ),
            itemCount: _categories.length,
            itemBuilder: (_, i) => _CategoryCard(
              category: _categories[i],
              onTap: () => onSearch(_categories[i].label),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _Category {
  final String label;
  final Color color;
  final IconData? icon;
  const _Category(this.label, this.color, this.icon);
}

class _CategoryCard extends StatelessWidget {
  final _Category category;
  final VoidCallback onTap;
  const _CategoryCard({required this.category, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: category.color,
          child: Stack(
            children: [
              Positioned(
                bottom: 8,
                left: 10,
                child: Text(
                  category.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (category.icon != null)
                Positioned(
                  top: 8,
                  right: 10,
                  child: Icon(category.icon,
                      color: Colors.white.withOpacity(0.4), size: 36),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── YouTube-style video card ─────────────────────────────────────────────────

class _VideoCard extends ConsumerStatefulWidget {
  final Song song;
  final bool isCurrentlyPlaying;
  final bool isSelected;
  final VoidCallback onTap;

  const _VideoCard({
    required this.song,
    required this.isCurrentlyPlaying,
    required this.isSelected,
    required this.onTap,
  });

  @override
  ConsumerState<_VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends ConsumerState<_VideoCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(youtubeServiceProvider).prefetchUrl(widget.song.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isCurrentlyPlaying = widget.isCurrentlyPlaying;
    final isSelected = widget.isSelected;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1A2A1A) : const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(
                  color: const Color(0xFF1DB954).withAlpha(100), width: 1.5)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 16:9 Thumbnail
            Stack(
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: song.thumbnailUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: const Color(0xFF212121),
                        child: const Center(
                          child: Icon(Icons.music_video,
                              color: Color(0xFF3A3A3A), size: 40),
                        ),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: const Color(0xFF212121),
                        child: const Center(
                          child: Icon(Icons.music_video,
                              color: Color(0xFF3A3A3A), size: 40),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(210),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatDuration(song.duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (isCurrentlyPlaying)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(12)),
                      child: Container(
                        color: Colors.black.withAlpha(100),
                        child: const Center(
                          child: Icon(Icons.graphic_eq,
                              color: Color(0xFF1DB954), size: 48),
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            // Info row
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? const Color(0xFF1DB954)
                                : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.person_outline,
                                size: 13, color: Color(0xFF6A6A6A)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                song.channelName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF9A9A9A),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _VideoOptionsMenu(song: song),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ─── Options menu ─────────────────────────────────────────────────────────────

class _VideoOptionsMenu extends ConsumerWidget {
  final Song song;
  const _VideoOptionsMenu({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Color(0xFF6A6A6A), size: 20),
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: EdgeInsets.zero,
      onSelected: (action) async {
        switch (action) {
          case 'next':
            ref.read(playerProvider.notifier).playNext(song);
            _snack(context, '▶  Will play next');
            break;
          case 'queue':
            ref.read(playerProvider.notifier).addToQueue(song);
            _snack(context, '+ Added to queue');
            break;
          case 'like':
            try {
              await ref.read(libraryProvider.notifier).toggleLike(song);
              if (context.mounted) {
                final isLiked = ref.read(libraryProvider).isLiked(song.id);
                _snack(
                    context,
                    isLiked
                        ? 'Removed from Liked Songs'
                        : 'Added to Liked Songs');
              }
            } catch (e) {
              if (context.mounted) {
                _snack(context, 'Failed to like song: $e');
              }
            }
            break;
          case 'playlist':
            _showAddToPlaylist(context, ref);
            break;
        }
      },
      itemBuilder: (_) {
        final isLiked = ref.read(libraryProvider).isLiked(song.id);
        return [
          _menuItem(Icons.skip_next_outlined, 'Play next', 'next'),
          _menuItem(Icons.queue_music_outlined, 'Add to queue', 'queue'),
          _menuItem(
            isLiked ? Icons.favorite : Icons.favorite_border,
            isLiked ? 'Unlike' : 'Like',
            'like',
            iconColor: isLiked ? const Color(0xFF1DB954) : null,
          ),
          _menuItem(Icons.playlist_add, 'Add to playlist', 'playlist'),
        ];
      },
    );
  }

  PopupMenuItem<String> _menuItem(IconData icon, String label, String value,
      {Color? iconColor}) {
    return PopupMenuItem(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, color: iconColor ?? const Color(0xFFB3B3B3), size: 20),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1DB954),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _showAddToPlaylist(BuildContext context, WidgetRef ref) {
    final playlists = ref.read(libraryProvider).playlists;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF3A3A3A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Add to playlist',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold)),
          const Divider(color: Color(0xFF282828), height: 20),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No playlists yet.\nCreate one in the Library tab.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFB3B3B3)),
              ),
            )
          else
            ...playlists.map((pl) => ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1DB954).withAlpha(30),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.queue_music,
                        color: Color(0xFF1DB954), size: 22),
                  ),
                  title: Text(pl.name,
                      style: const TextStyle(color: Colors.white)),
                  subtitle: Text('${pl.songs.length} songs',
                      style: const TextStyle(
                          color: Color(0xFF6A6A6A), fontSize: 12)),
                  onTap: () {
                    ref
                        .read(libraryProvider.notifier)
                        .addSongToPlaylistObj(pl, song);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Added to "${pl.name}"'),
                      backgroundColor: const Color(0xFF1DB954),
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ─── Search history / empty state ────────────────────────────────────────────

class _SearchHistoryOrEmpty extends ConsumerWidget {
  final String query;
  final Function(String) onSearch;

  const _SearchHistoryOrEmpty({required this.query, required this.onSearch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Center(
          child: Column(
            children: [
              const Icon(Icons.search_off, size: 56, color: Color(0xFF3A3A3A)),
              const SizedBox(height: 16),
              Text(
                'No results for\n"$query"',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 16),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => onSearch(query),
                icon: const Icon(Icons.refresh, color: Color(0xFF1DB954)),
                label: const Text('Try again',
                    style: TextStyle(color: Color(0xFF1DB954))),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
