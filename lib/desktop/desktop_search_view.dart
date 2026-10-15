// ============================================================
// desktop/desktop_search_view.dart
// Full-page search for desktop layout.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../models/ytmusic_models.dart';
import '../providers/player_provider.dart';
import '../providers/youtube_provider.dart';
import '../providers/ytmusic_home_provider.dart';
import '../widgets/song_context_menu.dart';
import '../widgets/artist_link.dart';
import 'shell/desktop_navigation.dart';
import 'theme/desktop_theme.dart';

class DesktopSearchView extends ConsumerStatefulWidget {
  const DesktopSearchView({super.key});

  @override
  ConsumerState<DesktopSearchView> createState() => _DesktopSearchViewState();
}

class _DesktopSearchViewState extends ConsumerState<DesktopSearchView> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    // The desktop search field lives in the title bar and drives searchProvider;
    // reuse its committed query for the mixed (artist/album) lookup.
    final query = searchState.query.trim();
    final extras = query.isEmpty
        ? null
        : ref.watch(ytSearchAllProvider(query)).valueOrNull;

    return Container(
      decoration: BoxDecoration(
        color: context.appTheme.panelSurfaceColor,
        borderRadius: BorderRadius.all(
          Radius.circular(context.appTheme.layout.panelRadius),
        ),
      ),
      child: _buildBody(searchState, extras),
    );
  }

  Widget _buildBody(SearchState searchState, YtSearchResults? extras) {
    final hasExtras = extras != null &&
        (extras.artists.isNotEmpty || extras.albums.isNotEmpty);
    if (searchState.isLoading) {
      return Center(
        child: CircularProgressIndicator(
            color: context.appTheme.isVerdantNightDesktop
                ? context.appTheme.subtext
                : context.appTheme.button),
      );
    }

    if (searchState.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: context.appTheme.notificationError, size: 40),
            SizedBox(height: 12),
            Text(
              searchState.error!,
              style: TextStyle(color: context.appTheme.subtext),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (searchState.results.isEmpty && searchState.query.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, color: context.appTheme.subtext, size: 56),
            SizedBox(height: 12),
            Text(
              'Search for songs, artists, or albums',
              style: TextStyle(color: context.appTheme.subtext, fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (searchState.results.isEmpty && !hasExtras) {
      return Center(
        child: Text(
          'No results for "${searchState.query}"',
          style: TextStyle(color: context.appTheme.subtext, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: 8),
      itemCount: searchState.results.length + (hasExtras ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (hasExtras && i == 0) {
          return _SearchExtras(extras: extras);
        }
        final song = searchState.results[hasExtras ? i - 1 : i];
        final durationStr = song.duration != Duration.zero
            ? '${song.duration.inMinutes}:${(song.duration.inSeconds % 60).toString().padLeft(2, '0')}'
            : '';

        return SongContextMenu(
          song: song,
          child: _SearchResultRow(
            song: song,
            index: i,
            durationStr: durationStr,
            allResults: searchState.results,
          ),
        );
      },
    );
  }
}

// ─── Search result row ────────────────────────────────────────────────────────

class _SearchResultRow extends ConsumerStatefulWidget {
  final Song song;
  final int index;
  final String durationStr;
  final List<Song> allResults;

  const _SearchResultRow({
    required this.song,
    required this.index,
    required this.durationStr,
    required this.allResults,
  });

  @override
  ConsumerState<_SearchResultRow> createState() => _SearchResultRowState();
}

class _SearchResultRowState extends ConsumerState<_SearchResultRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(playerProvider);
    final isPlaying = ps.currentSong?.id == widget.song.id && ps.isPlaying;
    final isCurrent = ps.currentSong?.id == widget.song.id;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: isCurrent
            ? context.appTheme.selectedRow // green tint when current
            : _hovered
                ? context.appTheme.highlight
                : context.appTheme.main.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => ref.read(playerProvider.notifier).playSong(
            widget.song,
            queue: [widget.song],
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // Index — green speaker icon when this song is current
                SizedBox(
                  width: 28,
                  child: isCurrent
                      ? Icon(
                          isPlaying ? Icons.volume_up : Icons.volume_mute,
                          // This is the "currently playing" marker, not a
                          // decorative icon — iconColor() demotes it to grey in
                          // Verdant Night and the row highlight disappeared.
                          color: context.appTheme.nowPlayingAccent,
                          size: 16,
                        )
                      : Text(
                          '${widget.index + 1}',
                          style: TextStyle(
                              color: context.appTheme.subtext, fontSize: 13),
                          textAlign: TextAlign.right,
                        ),
                ),
                SizedBox(width: 16),

                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: widget.song.thumbnailUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: widget.song.thumbnailUrl,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                              width: 48,
                              height: 48,
                              color: context.appTheme.card),
                          errorWidget: (_, __, ___) => Container(
                            width: 48,
                            height: 48,
                            color: context.appTheme.card,
                            child: Icon(Icons.music_note,
                                color: context.appTheme.subtext
                                    .withValues(alpha: 0.54),
                                size: 20),
                          ),
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: context.appTheme.card,
                          child: Icon(Icons.music_note,
                              color: context.appTheme.subtext
                                  .withValues(alpha: 0.54),
                              size: 20),
                        ),
                ),
                SizedBox(width: 16),

                // Title + artist — green when current
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent && !context.appTheme.isVerdantNightDesktop
                              ? context.appTheme.button
                              : context.appTheme.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: 2),
                      ArtistNames(
                        refs: widget.song.artistRefs,
                        fallbackName: widget.song.channelName,
                        maxLines: 1,
                        style: TextStyle(
                          color: isCurrent && !context.appTheme.isVerdantNightDesktop
                              ? context.appTheme.button.withValues(alpha: 0.7)
                              : context.appTheme.subtext,
                          fontSize: 12,
                        ),
                        hoverStyle: TextStyle(
                          color: context.appTheme.text,
                          fontSize: 12,
                          decoration: TextDecoration.underline,
                          decorationColor: context.appTheme.text,
                        ),
                      ),
                    ],
                  ),
                ),

                // Duration
                if (widget.durationStr.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      widget.durationStr,
                      style: TextStyle(
                        color: isCurrent && !context.appTheme.isVerdantNightDesktop
                            ? context.appTheme.button.withValues(alpha: 0.7)
                            : context.appTheme.subtext,
                        fontSize: 13,
                      ),
                    ),
                  ),

                // ··· menu button
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: SongMenuButton(song: widget.song),
                ),
                SizedBox(width: 4),

                // Play button — pause icon when this song is playing
                IconButton(
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: context.appTheme.nowPlayingAccent,
                    size: 32,
                  ),
                  onPressed: () {
                    if (isCurrent) {
                      ref.read(playerProvider.notifier).togglePlayPause();
                    } else {
                      ref.read(playerProvider.notifier).playSong(
                        widget.song,
                        queue: [widget.song],
                      );
                    }
                  },
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Artist / album results header ────────────────────────────────────────────

/// Rendered as the first item of the desktop result list: the artist and
/// album matches from YouTube Music, above the song rows.
class _SearchExtras extends ConsumerWidget {
  final YtSearchResults extras;

  const _SearchExtras({required this.extras});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (extras.artists.isNotEmpty) ...[
          const _ExtrasLabel('Artists'),
          SizedBox(
            height: 168,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: extras.artists.length,
              itemBuilder: (_, i) {
                final artist = extras.artists[i];
                return _ExtraArtistCard(artist: artist);
              },
            ),
          ),
        ],
        if (extras.albums.isNotEmpty) ...[
          const _ExtrasLabel('Albums'),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: extras.albums.length,
              itemBuilder: (_, i) {
                final album = extras.albums[i];
                return _ExtraAlbumCard(album: album);
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        Divider(
          color: context.appTheme.subtext.withValues(alpha: 0.15),
          height: 1,
        ),
      ],
    );
  }
}

class _ExtrasLabel extends StatelessWidget {
  final String text;
  const _ExtrasLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: context.appTheme.subtext,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _ExtraArtistCard extends ConsumerStatefulWidget {
  final YtArtist artist;
  const _ExtraArtistCard({required this.artist});

  @override
  ConsumerState<_ExtraArtistCard> createState() => _ExtraArtistCardState();
}

class _ExtraArtistCardState extends ConsumerState<_ExtraArtistCard> {
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
          width: 120,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            children: [
              AnimatedScale(
                scale: _hovered ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: ClipOval(
                  child: widget.artist.pictureUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: widget.artist.pictureUrl,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _placeholder(theme),
                        )
                      : _placeholder(theme),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(AppThemeData theme) => Container(
        width: 120,
        height: 120,
        color: theme.card,
        child: Icon(Icons.person, size: 44, color: theme.subtext),
      );
}

class _ExtraAlbumCard extends ConsumerStatefulWidget {
  final YtAlbum album;
  const _ExtraAlbumCard({required this.album});

  @override
  ConsumerState<_ExtraAlbumCard> createState() => _ExtraAlbumCardState();
}

class _ExtraAlbumCardState extends ConsumerState<_ExtraAlbumCard> {
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
        onTap: () =>
            ref.read(desktopYtBrowseRequestProvider.notifier).state = a.browseId,
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
