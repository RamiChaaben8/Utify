// ============================================================
// desktop/home/desktop_home_view.dart
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ytmusic_models.dart';
import '../../models/song.dart';
import '../../providers/ytmusic_home_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../shell/desktop_navigation.dart';
import '../theme/desktop_theme.dart';
import '../../utils/thumbnail_url.dart';
import '../../widgets/app_thumbnail.dart';

// ─── Layout constants ─────────────────────────────────────────────────────────

const _kSkeletonColor = Color(0xFF2A2A2A);

/// Font sizes and line heights for the card text block.
/// All heights are *exact* so we can compute card height without a layout pass.
const _kCardTitleSize = 13.0;
const _kCardTitleHeight = 1.3; // line-height multiplier → ~16.9 px per line
const _kCardSubtitleSize = 11.0;
const _kCardSubtitleHeight = 1.3; // → ~14.3 px per line
const _kCardTextGapAbove = 8.0; // gap between image and title
const _kCardTextGapBetween = 2.0; // gap between title and subtitle

/// Height of the text block for a card with [titleLines] and [subtitleLines].
double _cardTextBlockHeight(int titleLines, int subtitleLines) {
  return _kCardTextGapAbove +
      (_kCardTitleSize * _kCardTitleHeight * titleLines) +
      _kCardTextGapBetween +
      (_kCardSubtitleSize * _kCardSubtitleHeight * subtitleLines);
}

/// Total card height = square cover + text block.
double _cardTotalHeight(double cardWidth, int titleLines, int subtitleLines) {
  return cardWidth + _cardTextBlockHeight(titleLines, subtitleLines);
}

// ─── Image URL helpers ────────────────────────────────────────────────────────

/// Best cover URL for a [YtSong], falling back to a square YouTube thumbnail.
String _songCoverUrl(YtSong song) {
  return ThumbnailUrl.normalize(song.coverUrl, videoId: song.videoId);
}

/// Best cover URL for a local [Song], falling back to YouTube thumbnail.
String _localSongCoverUrl(Song song) {
  return ThumbnailUrl.normalize(
    song.thumbnailUrl,
    videoId: song.isLocal ? null : song.id,
  );
}

// ─── Top-level view ───────────────────────────────────────────────────────────

class DesktopHomeView extends ConsumerWidget {
  const DesktopHomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final library = ref.watch(libraryProvider);

    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 20)),

        // ── Mood chips ─────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _MoodChipsRow(
            selectedMood: feed.selectedMood,
            isMoodLoading: feed.moodState.isLoading,
            onSelect: (mood) =>
                ref.read(homeFeedProvider.notifier).selectMood(
                      mood == feed.selectedMood ? null : mood,
                    ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),

        // ── Full-page skeleton ─────────────────────────────────────────────
        if (feed.isLoading &&
            feed.quickPicks.isEmpty &&
            feed.newReleases.isEmpty &&
            feed.albumsForYou.isEmpty) ...[
          const SliverToBoxAdapter(child: _SkeletonLoader()),
        ]

        // ── Full-page error ────────────────────────────────────────────────
        else if (feed.error != null &&
            feed.quickPicks.isEmpty &&
            feed.newReleases.isEmpty) ...[
          SliverToBoxAdapter(
            child: _ErrorState(
              message: feed.error!,
              onRetry: () => ref.read(homeFeedProvider.notifier).refresh(),
            ),
          ),
        ]

        // ── Content ────────────────────────────────────────────────────────
        else ...[
          // Mood active banner
          if (feed.selectedMood != null)
            SliverToBoxAdapter(
              child: _MoodBanner(
                mood: feed.selectedMood!,
                isLoading: feed.moodState.isLoading,
                onClear: () =>
                    ref.read(homeFeedProvider.notifier).selectMood(null),
              ),
            ),

          // ── Quick Picks ────────────────────────────────────────────────
          if (feed.effectiveQuickPicks.isNotEmpty)
            SliverToBoxAdapter(
              child: _QuickPicksSection(
                songs: feed.effectiveQuickPicks,
                onTap: (song) =>
                    ref.read(playerProvider.notifier).playSong(song.toSong()),
              ),
            )
          else if (feed.quickPicksState.isFailed)
            SliverToBoxAdapter(
              child: _RetryRow(
                label: 'QUICK PICKS',
                error: feed.quickPicksState.error ?? 'Could not load',
                onRetry: () =>
                    ref.read(homeFeedProvider.notifier).retryQuickPicks(),
              ),
            ),

          // ── Listen Again (hidden when mood active) ─────────────────────
          if (feed.selectedMood == null) ...[
            SliverToBoxAdapter(
              child: Builder(builder: (context) {
                final items = library.recentlyPlayed
                    .where((s) => _localSongCoverUrl(s).isNotEmpty)
                    .take(12)
                    .toList();
                if (items.isEmpty) return const SizedBox.shrink();
                return _HorizontalCardSection(
                  label: 'LISTEN AGAIN',
                  title: 'Your recently played',
                  titleLines: 1,
                  subtitleLines: 1,
                  children: items
                      .map((s) => _SongCard(song: s, ref: ref))
                      .toList(),
                );
              }),
            ),
          ],

          // ── Because You Listened To ────────────────────────────────────
          if (feed.effectiveBecause.isNotEmpty)
            SliverToBoxAdapter(
              child: _HorizontalCardSection(
                label: 'BECAUSE YOU LISTENED TO',
                title: feed.becauseArtistName ?? 'your top artist',
                titleLines: 1,
                subtitleLines: 1,
                children: feed.effectiveBecause
                    .take(12)
                    .map((s) => _YtSongCard(song: s, ref: ref))
                    .toList(),
              ),
            ),

          // ── Mixed For You ──────────────────────────────────────────────
          if (feed.effectiveMixed.isNotEmpty)
            SliverToBoxAdapter(
              child: _HorizontalCardSection(
                label: 'MIXED FOR YOU',
                title: 'A blend of your favorites',
                titleLines: 1,
                subtitleLines: 1,
                children: feed.effectiveMixed
                    .take(12)
                    .map((s) => _YtSongCard(song: s, ref: ref))
                    .toList(),
              ),
            ),

          // ── Trending ───────────────────────────────────────────────────
          if (feed.effectiveTrending.isNotEmpty)
            SliverToBoxAdapter(
              child: _HorizontalCardSection(
                label: 'TRENDING',
                title: "What's trending now",
                titleLines: 1,
                subtitleLines: 1,
                children: feed.effectiveTrending
                    .take(12)
                    .map((s) => _YtSongCard(song: s, ref: ref))
                    .toList(),
              ),
            ),

          // ── Artists You Might Like ─────────────────────────────────────
          if (feed.effectiveArtists.isNotEmpty)
            SliverToBoxAdapter(
              child: _ArtistSection(
                artists: feed.effectiveArtists.take(12).toList(),
              ),
            ),

          // ── Forgotten Favorites (hidden when mood active) ──────────────
          if (feed.selectedMood == null) ...[
            SliverToBoxAdapter(
              child: Builder(builder: (context) {
                final items = _forgottenFavorites(library);
                if (items.isEmpty) return const SizedBox.shrink();
                return _HorizontalCardSection(
                  label: 'FORGOTTEN FAVORITES',
                  title: "Songs you loved but haven't played lately",
                  titleLines: 1,
                  subtitleLines: 1,
                  children: items
                      .map((s) => _SongCard(song: s, ref: ref))
                      .toList(),
                );
              }),
            ),
          ],
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }

  List<Song> _forgottenFavorites(LibraryState library) {
    final recentIds = library.recentlyPlayed.map((s) => s.id).toSet();
    return library.likedSongs
        .where((s) =>
            !recentIds.contains(s.id) &&
            _localSongCoverUrl(s).isNotEmpty)
        .take(12)
        .toList();
  }
}

// ─── Mood banner ──────────────────────────────────────────────────────────────

class _MoodBanner extends StatelessWidget {
  final HomeMood mood;
  final bool isLoading;
  final VoidCallback onClear;

  const _MoodBanner({
    required this.mood,
    required this.isLoading,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.button.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.button.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            if (isLoading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: theme.button),
              )
            else
              Icon(Icons.mood, size: 18, color: theme.button),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isLoading
                    ? 'Loading ${mood.label} music…'
                    : 'Showing music for: ${mood.label}',
                style: TextStyle(
                    color: theme.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
            GestureDetector(
              onTap: onClear,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.close, size: 16, color: theme.subtext),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Mood chips row ───────────────────────────────────────────────────────────

class _MoodChipsRow extends StatelessWidget {
  final HomeMood? selectedMood;
  final bool isMoodLoading;
  final ValueChanged<HomeMood> onSelect;

  const _MoodChipsRow({
    required this.selectedMood,
    required this.isMoodLoading,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: HomeMood.values.length,
        itemBuilder: (context, i) {
          final mood = HomeMood.values[i];
          final selected = selectedMood == mood;
          final loadingThis = selected && isMoodLoading;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onSelect(mood),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? theme.button : theme.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? theme.button : theme.shadow,
                      width: 1,
                    ),
                  ),
                  child: loadingThis
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: theme.onButtonFill,
                          ),
                        )
                      : Text(
                          mood.label,
                          style: TextStyle(
                            color: selected
                                ? theme.onButtonFill
                                : theme.text,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Retry row ────────────────────────────────────────────────────────────────

class _RetryRow extends StatelessWidget {
  final String label;
  final String error;
  final VoidCallback onRetry;

  const _RetryRow({
    required this.label,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 1, color: theme.shadow),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: theme.subtext,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 16, color: theme.subtext),
              const SizedBox(width: 8),
              Expanded(
                child: Text("Couldn't load.",
                    style: TextStyle(color: theme.subtext, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: theme.button,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Quick Picks ─────────────────────────────────────────────────────────────

class _QuickPicksSection extends StatelessWidget {
  final List<YtSong> songs;
  final ValueChanged<YtSong> onTap;

  const _QuickPicksSection(
      {required this.songs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    const rowsPerPage = 4;
    const rowH = 56.0;
    const rowGap = 8.0;
    const sectionH = rowsPerPage * rowH + (rowsPerPage - 1) * rowGap;

    final pages = <List<YtSong>>[];
    for (var i = 0; i < songs.length; i += rowsPerPage) {
      pages.add(songs.sublist(i, (i + rowsPerPage).clamp(0, songs.length)));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            label: 'QUICK PICKS',
            title: 'Songs you might like',
            theme: theme,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: sectionH,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: pages.length,
              itemBuilder: (ctx, pi) => Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: pages[pi].asMap().entries.map((e) {
                    final isLast = e.key == pages[pi].length - 1;
                    return Padding(
                      padding: EdgeInsets.only(bottom: isLast ? 0 : rowGap),
                      child: _QuickPickRow(
                        song: e.value,
                        onTap: () => onTap(e.value),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickPickRow extends StatefulWidget {
  final YtSong song;
  final VoidCallback onTap;
  const _QuickPickRow({required this.song, required this.onTap});

  @override
  State<_QuickPickRow> createState() => _QuickPickRowState();
}

class _QuickPickRowState extends State<_QuickPickRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final imageUrl = _songCoverUrl(widget.song);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 310,
          height: 56,
          decoration: BoxDecoration(
            color: _hovered ? theme.highlightElevated : theme.card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Square cover — BoxFit.cover crops any aspect ratio
              AppThumbnail(
                imageUrl: imageUrl,
                videoId: widget.song.videoId,
                width: 56,
                height: 56,
                borderRadius: 8,
                backgroundColor: theme.card,
                errorWidget: _placeholder(56, 56, theme),
                placeholder: _placeholder(56, 56, theme),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: theme.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(widget.song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: theme.subtext, fontSize: 12)),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Icon(Icons.play_circle_fill,
                        color: theme.button, size: 28),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Generic horizontal card section ─────────────────────────────────────────
// Computes exact carousel height from card width + text block heights,
// so there is never overflow regardless of window size.

class _HorizontalCardSection extends StatefulWidget {
  final String label;
  final String title;
  final List<Widget> children;
  final int titleLines;
  final int subtitleLines;

  const _HorizontalCardSection({
    required this.label,
    required this.title,
    required this.children,
    this.titleLines = 1,
    this.subtitleLines = 1,
  });

  @override
  State<_HorizontalCardSection> createState() =>
      _HorizontalCardSectionState();
}

class _HorizontalCardSectionState
    extends State<_HorizontalCardSection> {
  final _scroll = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    setState(() {
      _canScrollLeft = _scroll.offset > 0;
      _canScrollRight =
          _scroll.offset < _scroll.position.maxScrollExtent - 1;
    });
  }

  void _scrollBy(double dx) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      (_scroll.offset + dx).clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 1,
                          margin: const EdgeInsets.only(bottom: 8),
                          color: theme.shadow),
                      Text(widget.label,
                          style: TextStyle(
                              color: theme.subtext,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2)),
                      const SizedBox(height: 3),
                      Text(widget.title,
                          style: TextStyle(
                              color: theme.button,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity:
                      (_canScrollLeft || _canScrollRight) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Row(children: [
                    _NavArrow(
                        icon: Icons.chevron_left,
                        enabled: _canScrollLeft,
                        onTap: () => _scrollBy(-400),
                        theme: theme),
                    const SizedBox(width: 4),
                    _NavArrow(
                        icon: Icons.chevron_right,
                        enabled: _canScrollRight,
                        onTap: () => _scrollBy(400),
                        theme: theme),
                  ]),
                ),
              ],
            ),
          ),

          // Card row — LayoutBuilder drives both width and exact height
          LayoutBuilder(builder: (context, constraints) {
            final cardWidth = _computeCardWidth(constraints.maxWidth);
            final carouselH = _cardTotalHeight(
                cardWidth, widget.titleLines, widget.subtitleLines);

            return SizedBox(
              height: carouselH,
              child: ListView.builder(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: widget.children.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: cardWidth,
                    child: widget.children[i],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─── Artists section (separate widget — round cards, fixed 220 height) ────────

class _ArtistSection extends StatefulWidget {
  final List<YtArtist> artists;
  const _ArtistSection({required this.artists});

  @override
  State<_ArtistSection> createState() => _ArtistSectionState();
}

class _ArtistSectionState extends State<_ArtistSection> {
  final _scroll = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    setState(() {
      _canScrollLeft = _scroll.offset > 0;
      _canScrollRight =
          _scroll.offset < _scroll.position.maxScrollExtent - 1;
    });
  }

  // Artist card: circular image 160px + 10px gap + title 13px*1.3 + 2px + "Artist" 11px*1.3
  // = 160 + 10 + 16.9 + 2 + 14.3 = 203.2 → round to 208 for breathing room
  static const double _artistCardH = 208;
  static const double _imageSize = 160;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 1,
                          margin: const EdgeInsets.only(bottom: 8),
                          color: theme.shadow),
                      Text('ARTISTS YOU MIGHT LIKE',
                          style: TextStyle(
                              color: theme.subtext,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2)),
                      const SizedBox(height: 3),
                      Text('Similar to your favorites',
                          style: TextStyle(
                              color: theme.button,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity: (_canScrollLeft || _canScrollRight) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Row(children: [
                    _NavArrow(
                        icon: Icons.chevron_left,
                        enabled: _canScrollLeft,
                        onTap: () {
                          if (!_scroll.hasClients) return;
                          _scroll.animateTo(
                              (_scroll.offset - 400).clamp(
                                  0.0, _scroll.position.maxScrollExtent),
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic);
                        },
                        theme: theme),
                    const SizedBox(width: 4),
                    _NavArrow(
                        icon: Icons.chevron_right,
                        enabled: _canScrollRight,
                        onTap: () {
                          if (!_scroll.hasClients) return;
                          _scroll.animateTo(
                              (_scroll.offset + 400).clamp(
                                  0.0, _scroll.position.maxScrollExtent),
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic);
                        },
                        theme: theme),
                  ]),
                ),
              ],
            ),
          ),
          SizedBox(
            height: _artistCardH,
            child: ListView.builder(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: widget.artists.length,
              itemBuilder: (ctx, i) => Padding(
                padding: const EdgeInsets.only(right: 16),
                child: SizedBox(
                  width: _imageSize,
                  child:
                      _YtArtistCard(artist: widget.artists[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Nav arrow ────────────────────────────────────────────────────────────────

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final AppThemeData theme;

  const _NavArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: enabled ? theme.card : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Icon(icon,
              size: 20,
              color: enabled
                  ? theme.text
                  : theme.subtext.withValues(alpha: 0.4)),
        ),
      ),
    );
  }
}

// ─── Section header (Quick Picks uses this standalone) ───────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final String title;
  final AppThemeData theme;

  const _SectionHeader(
      {required this.label, required this.title, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 1, color: theme.shadow),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: theme.subtext,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 3),
          Text(title,
              style: TextStyle(
                  color: theme.button,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ─── Shared image widget — always square, BoxFit.cover, no letterboxing ───────

Widget _squareImage(String url, double size, double radius,
    AppThemeData theme) {
  return AppThumbnail(
    imageUrl: url,
    width: size,
    height: size,
    borderRadius: radius,
    backgroundColor: theme.card,
    errorWidget: _placeholder(size, size, theme, radius: radius),
    placeholder: _placeholder(size, size, theme, radius: radius),
  );
}

Widget _placeholder(double w, double h, AppThemeData theme,
    {double radius = 0}) {
  return Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: theme.card,
      borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
    ),
    child: Icon(Icons.music_note,
        color: theme.subtext.withValues(alpha: 0.45),
        size: (w * 0.35).clamp(14.0, 48.0)),
  );
}

// ─── Local Song card ──────────────────────────────────────────────────────────

class _SongCard extends StatelessWidget {
  final Song song;
  final WidgetRef ref;

  const _SongCard({required this.song, required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return _CardBase(
      coverUrl: _localSongCoverUrl(song),
      title: song.title,
      subtitle: song.channelName,
      titleLines: 1,
      subtitleLines: 1,
      onTap: () => ref.read(playerProvider.notifier).playSong(song),
      theme: theme,
    );
  }
}

// ─── YtSong card ─────────────────────────────────────────────────────────────

class _YtSongCard extends StatelessWidget {
  final YtSong song;
  final WidgetRef ref;

  const _YtSongCard({required this.song, required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return _CardBase(
      coverUrl: _songCoverUrl(song),
      title: song.title,
      subtitle: song.artist,
      titleLines: 1,
      subtitleLines: 1,
      onTap: () =>
          ref.read(playerProvider.notifier).playSong(song.toSong()),
      theme: theme,
    );
  }
}

// ─── Albums For You card (2-line title, 2-line subtitle, explicit badge) ──────

class _AlbumCard extends ConsumerStatefulWidget {
  final YtAlbum album;

  const _AlbumCard({required this.album});

  @override
  ConsumerState<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<_AlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final a = widget.album;

    return LayoutBuilder(builder: (context, constraints) {
      final size =
          constraints.maxWidth.isFinite && constraints.maxWidth > 8
              ? constraints.maxWidth
              : 160.0;
      final radius = theme.layout.cardRadius.toDouble();

      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => ref
              .read(desktopYtBrowseRequestProvider.notifier)
              .state = a.browseId,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cover with hover overlay
              AnimatedScale(
                scale: _hovered ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: Stack(
                  children: [
                    _squareImage(a.coverUrl, size, radius, theme),
                    if (_hovered)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: Container(
                            color: Colors.black45,
                            child: Center(
                              child: Icon(Icons.play_circle_fill,
                                  color: theme.button, size: size * 0.38),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Text block — fixed height so no overflow
              const SizedBox(height: _kCardTextGapAbove),
              // Title: 2 lines
              SizedBox(
                height: _kCardTitleSize * _kCardTitleHeight * 2,
                child: Text(
                  a.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: _kCardTitleSize,
                    fontWeight: FontWeight.w600,
                    height: _kCardTitleHeight,
                  ),
                ),
              ),
              const SizedBox(height: _kCardTextGapBetween),
              // Subtitle: "EP • Artist" with optional explicit badge
              SizedBox(
                height: _kCardSubtitleSize * _kCardSubtitleHeight * 2,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (a.isExplicit) ...[
                      Container(
                        margin: const EdgeInsets.only(top: 1, right: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 3, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.subtext.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text('E',
                            style: TextStyle(
                                color: theme.subtext,
                                fontSize: 8,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                    Expanded(
                      child: Text(
                        a.displaySubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.subtext,
                          fontSize: _kCardSubtitleSize,
                          height: _kCardSubtitleHeight,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

// ─── YtArtist card (round) ────────────────────────────────────────────────────

class _YtArtistCard extends StatefulWidget {
  final YtArtist artist;
  const _YtArtistCard({required this.artist});

  @override
  State<_YtArtistCard> createState() => _YtArtistCardState();
}

class _YtArtistCardState extends State<_YtArtistCard> {
  bool _hovered = false;

  static const double _imageSize = 160;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Opening: ${widget.artist.name}'),
            duration: const Duration(seconds: 2))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _hovered ? 1.04 : 1.0,
              duration: const Duration(milliseconds: 160),
              child: Stack(
                children: [
                  ClipOval(
                    child: AppThumbnail(
                      imageUrl: widget.artist.pictureUrl,
                      width: _imageSize,
                      height: _imageSize,
                      borderRadius: _imageSize / 2,
                      backgroundColor: _kSkeletonColor,
                      placeholderIcon: Icons.person,
                      errorWidget: Container(
                        width: _imageSize,
                        height: _imageSize,
                        color: _kSkeletonColor,
                        child: const Icon(Icons.person,
                            color: Colors.white54,
                            size: _imageSize * 0.4),
                      ),
                    ),
                  ),
                  if (_hovered)
                    Positioned.fill(
                      child: ClipOval(
                        child: Container(
                          color: Colors.black45,
                          child: const Center(
                            child: Icon(Icons.play_circle_fill,
                                color: Colors.white,
                                size: _imageSize * 0.38),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Title — fixed height (1 line)
            SizedBox(
              height: _kCardTitleSize * _kCardTitleHeight,
              child: Text(
                widget.artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.text,
                  fontSize: _kCardTitleSize,
                  fontWeight: FontWeight.w600,
                  height: _kCardTitleHeight,
                ),
              ),
            ),
            const SizedBox(height: _kCardTextGapBetween),
            SizedBox(
              height: _kCardSubtitleSize * _kCardSubtitleHeight,
              child: Text(
                'Artist',
                style: TextStyle(
                  color: theme.subtext,
                  fontSize: _kCardSubtitleSize,
                  height: _kCardSubtitleHeight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Card base (song / album shared) ─────────────────────────────────────────
// Uses a fixed-height SizedBox for the text block so height is exactly
// predictable and the parent SizedBox never overflows.

class _CardBase extends StatefulWidget {
  final String coverUrl;
  final String title;
  final String subtitle;
  final int titleLines;
  final int subtitleLines;
  final VoidCallback onTap;
  final AppThemeData theme;

  const _CardBase({
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.theme,
    this.titleLines = 1,
    this.subtitleLines = 1,
  });

  @override
  State<_CardBase> createState() => _CardBaseState();
}

class _CardBaseState extends State<_CardBase> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final radius = t.layout.cardRadius.toDouble();

    return LayoutBuilder(builder: (context, constraints) {
      final size =
          constraints.maxWidth.isFinite && constraints.maxWidth > 8
              ? constraints.maxWidth
              : 160.0;

      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cover — always square, BoxFit.cover
              AnimatedScale(
                scale: _hovered ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: Stack(
                  children: [
                    _squareImage(widget.coverUrl, size, radius, t),
                    if (_hovered)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: Container(
                            color: Colors.black45,
                            child: Center(
                              child: Icon(Icons.play_circle_fill,
                                  color: t.button, size: size * 0.38),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Fixed-height text block — deterministic, never overflows
              const SizedBox(height: _kCardTextGapAbove),
              SizedBox(
                height:
                    _kCardTitleSize * _kCardTitleHeight * widget.titleLines,
                child: Text(
                  widget.title,
                  maxLines: widget.titleLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: _kCardTitleSize,
                    fontWeight: FontWeight.w600,
                    height: _kCardTitleHeight,
                  ),
                ),
              ),
              const SizedBox(height: _kCardTextGapBetween),
              SizedBox(
                height: _kCardSubtitleSize *
                    _kCardSubtitleHeight *
                    widget.subtitleLines,
                child: Text(
                  widget.subtitle,
                  maxLines: widget.subtitleLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.subtext,
                    fontSize: _kCardSubtitleSize,
                    height: _kCardSubtitleHeight,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

// ─── Skeleton loader (full page) ─────────────────────────────────────────────

class _SkeletonLoader extends StatelessWidget {
  const _SkeletonLoader();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = _computeCardWidth(constraints.maxWidth);
      final cardH = _cardTotalHeight(size, 1, 1);

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quick picks skeleton
            const _SkeletonBox(width: 120, height: 12, borderRadius: 4),
            const SizedBox(height: 8),
            const _SkeletonBox(width: 220, height: 24, borderRadius: 4),
            const SizedBox(height: 14),
            ...List.generate(4, (_) => const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    _SkeletonBox(width: 56, height: 56, borderRadius: 8),
                    SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SkeletonBox(width: 180, height: 13, borderRadius: 4),
                          SizedBox(height: 6),
                          _SkeletonBox(width: 120, height: 11, borderRadius: 4),
                        ]),
                  ]),
                )),
            const SizedBox(height: 32),
            // Three horizontal card sections
            ...List.generate(3, (_) => Padding(
                  padding: const EdgeInsets.only(bottom: 36),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SkeletonBox(width: 120, height: 12, borderRadius: 4),
                      const SizedBox(height: 8),
                      const _SkeletonBox(width: 200, height: 24, borderRadius: 4),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: cardH,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: 6,
                          itemBuilder: (_, __) => Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _SkeletonBox(
                                    width: size,
                                    height: size,
                                    borderRadius: 8),
                                const SizedBox(height: 8),
                                _SkeletonBox(
                                    width: size * 0.8,
                                    height: 13,
                                    borderRadius: 4),
                                const SizedBox(height: 4),
                                _SkeletonBox(
                                    width: size * 0.6,
                                    height: 11,
                                    borderRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      );
    });
  }
}

class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const _SkeletonBox(
      {required this.width,
      required this.height,
      required this.borderRadius});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _kSkeletonColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

// ─── Full-page error ──────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 64, color: theme.subtext),
            const SizedBox(height: 20),
            Text("Couldn't load your music",
                style: TextStyle(
                    color: theme.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              message.isNotEmpty
                  ? message
                  : 'Check your internet connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.subtext, fontSize: 14),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.button,
                foregroundColor: theme.onButtonFill,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared card-width computation ───────────────────────────────────────────

/// Computes the card width so a whole number of cards fits in [available] px,
/// with 20px padding on each side and 16px gaps between cards.
/// Preferred width ~160px, minimum 2 cards, maximum 12.
double _computeCardWidth(double available) {
  const preferred = 160.0;
  const gap = 16.0;
  const hPad = 40.0;

  final usable = available - hPad;
  if (usable <= 0) return preferred;

  final count =
      ((usable + gap) / (preferred + gap)).floor().clamp(2, 12);
  final w = (usable - gap * (count - 1)) / count;
  return w.clamp(120.0, 200.0);
}
