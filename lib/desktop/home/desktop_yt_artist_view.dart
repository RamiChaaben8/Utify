// desktop/home/desktop_yt_artist_view.dart
// Shows a YouTube Music artist page fetched by browseId: header (image, name,
// subscribers, description), top songs, albums, singles and related artists.
// Songs play through the existing player, exactly like everywhere else.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ytmusic_models.dart';
import '../../providers/player_provider.dart';
import '../../providers/ytmusic_home_provider.dart';
import '../shell/desktop_navigation.dart';
import '../theme/desktop_theme.dart';

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class DesktopYtArtistView extends ConsumerWidget {
  final String browseId;

  const DesktopYtArtistView({super.key, required this.browseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final async = ref.watch(artistProvider(browseId));

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
              Text('Could not load artist',
                  style: TextStyle(
                      color: theme.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(e.toString(),
                  style: TextStyle(color: theme.subtext, fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
        data: (data) => _ArtistBody(browseId: browseId, data: data),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _ArtistBody extends ConsumerWidget {
  final String browseId;
  final YtArtistData data;

  const _ArtistBody({required this.browseId, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final hasAnything = data.topSongs.isNotEmpty ||
        data.albums.isNotEmpty ||
        data.singles.isNotEmpty ||
        data.relatedArtists.isNotEmpty;

    return CustomScrollView(
      slivers: [
        // ── Header ────────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipOval(
                  child: data.pictureUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: data.pictureUrl,
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
                        data.name.isNotEmpty ? data.name : 'Artist',
                        style: TextStyle(
                          color: theme.text,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (data.subscribers.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          data.subscribers,
                          style: TextStyle(color: theme.subtext, fontSize: 13),
                        ),
                      ],
                      if (data.description.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: Text(
                            data.description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: theme.subtext,
                                fontSize: 12,
                                height: 1.4),
                          ),
                        ),
                      ],
                      if (data.topSongs.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () => _playAll(ref),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
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
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        SliverToBoxAdapter(child: Container(height: 1, color: theme.shadow)),

        // ── Neck: nothing found ───────────────────────────────────────────
        if (!hasAnything)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text('No songs or albums found',
                    style: TextStyle(color: theme.subtext)),
              ),
            ),
          ),

        // ── Top songs ─────────────────────────────────────────────────────
        if (data.topSongs.isNotEmpty)
          SliverToBoxAdapter(
            child: _SectionTitle(label: 'POPULAR', theme: theme),
          ),
        if (data.topSongs.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _SongRow(
                index: i + 1,
                song: data.topSongs[i],
                onTap: () => _playFrom(ref, i),
              ),
              childCount: data.topSongs.length,
            ),
          ),

        // ── Albums ────────────────────────────────────────────────────────
        if (data.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: _AlbumCarousel(
              label: 'ALBUMS',
              albums: data.albums,
            ),
          ),

        // ── Singles ───────────────────────────────────────────────────────
        if (data.singles.isNotEmpty)
          SliverToBoxAdapter(
            child: _AlbumCarousel(
              label: 'SINGLES',
              albums: data.singles,
            ),
          ),

        // ── Related artists ───────────────────────────────────────────────
        if (data.relatedArtists.isNotEmpty)
          SliverToBoxAdapter(
            child: _ArtistCarousel(artists: data.relatedArtists),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _artPlaceholder(AppThemeData theme) => Container(
        width: 180,
        height: 180,
        decoration: BoxDecoration(color: theme.card, shape: BoxShape.circle),
        child: Icon(Icons.person, size: 72, color: theme.subtext),
      );

  void _playAll(WidgetRef ref) {
    final songs = data.topSongs.map((s) => s.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(songs.first, queue: songs);
  }

  void _playFrom(WidgetRef ref, int index) {
    final songs = data.topSongs.map((s) => s.toSong()).toList();
    if (songs.isEmpty) return;
    ref.read(playerProvider.notifier).playSong(songs[index], queue: songs);
  }
}

// ---------------------------------------------------------------------------
// Section title
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  final String label;
  final AppThemeData theme;

  const _SectionTitle({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        label,
        style: TextStyle(
          color: theme.subtext,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Song row
// ---------------------------------------------------------------------------

class _SongRow extends StatefulWidget {
  final int index;
  final YtSong song;
  final VoidCallback onTap;

  const _SongRow({
    required this.index,
    required this.song,
    required this.onTap,
  });

  @override
  State<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<_SongRow> {
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
          color: _hovered ? theme.highlightElevated : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${widget.index}',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: theme.subtext, fontSize: 13),
                ),
              ),
              const SizedBox(width: 14),
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
              Expanded(
                child: Text(
                  widget.song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
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
        child: Icon(Icons.music_note, size: 18, color: theme.subtext),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------
// Album / single carousel
// ---------------------------------------------------------------------------

class _AlbumCarousel extends StatefulWidget {
  final String label;
  final List<YtAlbum> albums;

  const _AlbumCarousel({required this.label, required this.albums});

  @override
  State<_AlbumCarousel> createState() => _AlbumCarouselState();
}

class _AlbumCarouselState extends State<_AlbumCarousel> {
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
      _canScrollRight = _scroll.offset < _scroll.position.maxScrollExtent - 1;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: theme.subtext,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              _CarouselArrows(
                theme: theme,
                canScrollLeft: _canScrollLeft,
                canScrollRight: _canScrollRight,
                onLeft: () => _scrollBy(-400),
                onRight: () => _scrollBy(400),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 236,
          child: ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: widget.albums.length,
            itemBuilder: (ctx, i) => _AlbumCard(album: widget.albums[i]),
          ),
        ),
      ],
    );
  }
}

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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ref
            .read(desktopYtBrowseRequestProvider.notifier)
            .state = a.browseId,
        child: Container(
          width: 150,
          margin: const EdgeInsets.only(right: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: _hovered ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: a.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: a.coverUrl,
                          width: 150,
                          height: 150,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholder(theme),
                        )
                      : _placeholder(theme),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                a.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                [a.typeLabel, if (a.year != null) '${a.year}'].join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.subtext, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(AppThemeData theme) => Container(
        width: 150,
        height: 150,
        color: theme.card,
        child: Icon(Icons.album, size: 48, color: theme.subtext),
      );
}

// ---------------------------------------------------------------------------
// Related-artist carousel
// ---------------------------------------------------------------------------

class _ArtistCarousel extends StatefulWidget {
  final List<YtArtist> artists;

  const _ArtistCarousel({required this.artists});

  @override
  State<_ArtistCarousel> createState() => _ArtistCarouselState();
}

class _ArtistCarouselState extends State<_ArtistCarousel> {
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
      _canScrollRight = _scroll.offset < _scroll.position.maxScrollExtent - 1;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'FANS MIGHT ALSO LIKE',
                  style: TextStyle(
                    color: theme.subtext,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              _CarouselArrows(
                theme: theme,
                canScrollLeft: _canScrollLeft,
                canScrollRight: _canScrollRight,
                onLeft: () => _scrollBy(-400),
                onRight: () => _scrollBy(400),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: widget.artists.length,
            itemBuilder: (ctx, i) => _ArtistCard(artist: widget.artists[i]),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Carousel nav arrows
// ---------------------------------------------------------------------------

class _CarouselArrows extends StatelessWidget {
  final AppThemeData theme;
  final bool canScrollLeft;
  final bool canScrollRight;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  const _CarouselArrows({
    required this.theme,
    required this.canScrollLeft,
    required this.canScrollRight,
    required this.onLeft,
    required this.onRight,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: (canScrollLeft || canScrollRight) ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: Row(
        children: [
          _CarouselArrow(
            icon: Icons.chevron_left,
            enabled: canScrollLeft,
            onTap: onLeft,
            theme: theme,
          ),
          const SizedBox(width: 4),
          _CarouselArrow(
            icon: Icons.chevron_right,
            enabled: canScrollRight,
            onTap: onRight,
            theme: theme,
          ),
        ],
      ),
    );
  }
}

class _CarouselArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final AppThemeData theme;

  const _CarouselArrow({
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
          child: Icon(
            icon,
            size: 20,
            color: enabled ? theme.text : theme.subtext.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _ArtistCard extends ConsumerStatefulWidget {
  final YtArtist artist;
  const _ArtistCard({required this.artist});

  @override
  ConsumerState<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends ConsumerState<_ArtistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ref
            .read(desktopYtArtistRequestProvider.notifier)
            .state = widget.artist.browseId,
        child: Container(
          width: 150,
          margin: const EdgeInsets.only(right: 16),
          child: Column(
            children: [
              AnimatedScale(
                scale: _hovered ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: ClipOval(
                  child: widget.artist.pictureUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: widget.artist.pictureUrl,
                          width: 150,
                          height: 150,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholder(theme),
                        )
                      : _placeholder(theme),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.artist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 2),
              Text('Artist',
                  style: TextStyle(color: theme.subtext, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(AppThemeData theme) => Container(
        width: 150,
        height: 150,
        color: theme.card,
        child: Icon(Icons.person, size: 56, color: theme.subtext),
      );
}
