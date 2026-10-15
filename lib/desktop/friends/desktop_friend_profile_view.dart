// ============================================================
// desktop/friends/desktop_friend_profile_view.dart
//
// Desktop-only friend profile, shown in the shell's centre view. The
// friend activity panel asks for it through
// desktopFriendProfileRequestProvider, because the playlist grid needs
// the centre column and the panel is far too narrow for it.
//
// It is a page rather than a pushed route because the mobile
// FriendProfileScreen brought its own Scaffold + AppBar, which is why
// opening a friend used to drop you out of the desktop layout entirely.
//
// Playlists open in the real DesktopPlaylistView rather than the
// mobile PlaylistScreen — see desktop_navigation.dart for why that
// goes through a provider.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/firestore_service.dart';
import '../theme/desktop_theme.dart';
import '../shell/desktop_navigation.dart';

class DesktopFriendProfileView extends ConsumerStatefulWidget {
  final PublicProfile profile;
  final VoidCallback onBack;

  const DesktopFriendProfileView({
    super.key,
    required this.profile,
    required this.onBack,
  });

  @override
  ConsumerState<DesktopFriendProfileView> createState() =>
      _DesktopFriendProfileViewState();
}

class _DesktopFriendProfileViewState
    extends ConsumerState<DesktopFriendProfileView> {
  late Future<List<Playlist>> _playlists;
  String? _savingPlaylistKey;

  @override
  void initState() {
    super.initState();
    _playlists = FirestoreService().getFriendPlaylists(widget.profile.uid);
  }

  Future<void> _saveCopy(Playlist playlist) async {
    final key = playlist.sharedId ?? playlist.name;
    setState(() => _savingPlaylistKey = key);
    await ref
        .read(libraryProvider.notifier)
        .createPlaylistWithSongs('${playlist.name} (copy)', playlist.songs);
    if (!mounted) return;
    setState(() => _savingPlaylistKey = null);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
        content: Text('Saved a private copy to your library.'),
        duration: Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.panelSurfaceColor,
        borderRadius:
            BorderRadius.all(Radius.circular(theme.layout.panelRadius)),
      ),
      child: FutureBuilder<List<Playlist>>(
        future: _playlists,
        builder: (context, snapshot) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _ProfileHeader(
                  profile: widget.profile,
                  onBack: widget.onBack,
                ),
              ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snapshot.hasError)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorState(
                    message: 'Could not load ${widget.profile.username}'
                        "'s playlists.",
                    onRetry: () => setState(() {
                      _playlists = FirestoreService()
                          .getFriendPlaylists(widget.profile.uid);
                    }),
                  ),
                )
              else
                ..._buildPlaylistSlivers(snapshot.data ?? const []),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildPlaylistSlivers(List<Playlist> playlists) {
    final theme = context.appTheme;

    if (playlists.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _EmptyPlaylists(username: widget.profile.username),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(38, 4, 38, 14),
          child: Text(
            'Playlists',
            style: TextStyle(
              color: theme.nowPlayingAccent,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(38, 0, 38, 40),
        sliver: SliverGrid(
          gridDelegate:
              const SliverGridDelegateWithMaxCrossAxisExtent(
            // Card plus the 16px gutter the songs grid in the home view uses.
            maxCrossAxisExtent: 220,
            mainAxisExtent: 232,
            crossAxisSpacing: 16,
            mainAxisSpacing: 20,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _FriendPlaylistCard(
              playlist: playlists[i],
              busy: _savingPlaylistKey ==
                  (playlists[i].sharedId ?? playlists[i].name),
              onOpen: () => ref
                  .read(desktopPlaylistRequestProvider.notifier)
                  .state = playlists[i],
              onSaveCopy: () => _saveCopy(playlists[i]),
            ),
            childCount: playlists.length,
          ),
        ),
      ),
    ];
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final PublicProfile profile;
  final VoidCallback onBack;

  const _ProfileHeader({required this.profile, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final name = profile.displayName.isNotEmpty
        ? profile.displayName
        : '@${profile.username}';

    return Container(
      // Same gradient scrim the playlist header uses in Verdant Night.
      decoration: theme.usesModernDesign
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.headerGradientColor,
                  theme.main.withValues(alpha: 0),
                ],
              ),
            )
          : null,
      padding: const EdgeInsets.fromLTRB(38, 24, 38, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BackLink(onBack: onBack),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProfileAvatar(url: profile.photoURL, size: 104),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.nowPlayingAccent,
                        fontSize: 44,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '@${profile.username}',
                      style:
                          TextStyle(color: theme.subtext, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Text-and-chevron back control rather than an icon button, matching the
/// subtle "‹ Back" affordance desktop panels use over a filled circular arrow.
class _BackLink extends StatefulWidget {
  final VoidCallback onBack;

  const _BackLink({required this.onBack});

  @override
  State<_BackLink> createState() => _BackLinkState();
}

class _BackLinkState extends State<_BackLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final color = _hovered ? theme.iconColor(theme.text) : theme.subtext;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onBack,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left, size: 20, color: color),
              const SizedBox(width: 2),
              Text(
                'Back to friends',
                style: TextStyle(
                  color: color,
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
}

class _ProfileAvatar extends StatelessWidget {
  final String url;
  final double size;

  const _ProfileAvatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    Widget face;
    if (url.isEmpty) {
      face = _placeholder(theme);
    } else {
      face = CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: theme.card),
        errorWidget: (_, __, ___) => _placeholder(theme),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(width: size, height: size, child: face),
    );
  }

  Widget _placeholder(AppThemeData theme) {
    return Container(
      color: theme.card,
      child: Icon(
        Icons.person_outline,
        color: theme.subtext.withValues(alpha: 0.54),
        size: size * 0.4,
      ),
    );
  }
}

// ─── Playlist card ────────────────────────────────────────────────────────────

class _FriendPlaylistCard extends ConsumerStatefulWidget {
  final Playlist playlist;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onSaveCopy;

  const _FriendPlaylistCard({
    required this.playlist,
    required this.busy,
    required this.onOpen,
    required this.onSaveCopy,
  });

  @override
  ConsumerState<_FriendPlaylistCard> createState() =>
      _FriendPlaylistCardState();
}

class _FriendPlaylistCardState extends ConsumerState<_FriendPlaylistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final layout = theme.layout;
    final playlist = widget.playlist;
    final cover = playlist.coverThumbnail ?? '';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(layout.cardRadius),
                  child: cover.isEmpty
                      ? Container(
                          width: layout.homeCardSize,
                          height: layout.homeCardSize,
                          color: theme.card,
                          child: Icon(
                            Icons.queue_music,
                            color: theme.subtext.withValues(alpha: 0.54),
                            size: 40,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: cover,
                          width: layout.homeCardSize,
                          height: layout.homeCardSize,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            width: layout.homeCardSize,
                            height: layout.homeCardSize,
                            color: theme.card,
                          ),
                          errorWidget: (_, __, ___) => Container(
                            width: layout.homeCardSize,
                            height: layout.homeCardSize,
                            color: theme.card,
                            child: Icon(
                              Icons.queue_music,
                              color: theme.subtext.withValues(alpha: 0.54),
                              size: 40,
                            ),
                          ),
                        ),
                ),

                // Dark scrim so the hover play button stays legible on bright
                // artwork, same as the home-view cards.
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(layout.cardRadius),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            theme.main.withValues(alpha: 0),
                            theme.shadow.withValues(alpha: 0.67),
                          ],
                          stops: const [0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),

                if (playlist.songs.isNotEmpty)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _PlayBadge(
                      visible: _hovered,
                      onPressed: () => ref
                          .read(playerProvider.notifier)
                          .playSong(
                            playlist.songs.first,
                            queue: playlist.songs,
                          ),
                    ),
                  ),

                if (widget.busy)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(layout.cardRadius),
                      child: Container(
                        color: theme.main.withValues(alpha: 0.55),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (_hovered)
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: IconButton(
                      tooltip: 'Save a copy',
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      onPressed: widget.onSaveCopy,
                      icon: Icon(Icons.add, color: theme.subtext),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${playlist.songs.length} song'
              '${playlist.songs.length == 1 ? '' : 's'}',
              style: TextStyle(color: theme.subtext, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Round play button revealed on hover, matching the home-view card overlay.
class _PlayBadge extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;

  const _PlayBadge({required this.visible, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 150),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.button,
            ),
            // Sits on the accent fill, so the glyph must be onButtonFill,
            // not `text` (which is lime in Verdant Night).
            child: Icon(Icons.play_arrow,
                color: theme.onButtonFill, size: 26),
          ),
        ),
      ),
    );
  }
}

// ─── Empty / error ───────────────────────────────────────────────────────────

class _EmptyPlaylists extends StatelessWidget {
  final String username;

  const _EmptyPlaylists({required this.username});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined, size: 56, color: theme.iconDefault),
          const SizedBox(height: 12),
          Text(
            'No public playlists',
            style: TextStyle(
              color: theme.subtext,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '@$username has not shared any playlists yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.subtext, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: theme.notificationError, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.subtext),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.iconColor(theme.text),
                side: BorderSide(color: theme.dividerColor),
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: const StadiumBorder(),
              ),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
