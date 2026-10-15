// ============================================================
// desktop/shell/desktop_title_bar.dart
// 64px top bar — sits inside Flutter content area.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../../models/song.dart';
import '../../models/ytmusic_models.dart';
import '../../providers/player_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/guest_session_provider.dart';
import '../../providers/search_history_provider.dart';
import '../../providers/youtube_provider.dart';
import '../../providers/ytmusic_home_provider.dart';
import '../../widgets/artist_link.dart';
import '../theme/desktop_theme.dart';
import '../../widgets/listen_party_controls.dart';

// ── Centre-view index, mirroring the shell's own constant. Search and
// ── playlists are shown by the centre column itself, so home is the only one
// ── the title bar needs an active state for. ─────────────────────────────────
const int _kViewHome = 0;

/// Active-state colour for a title-bar icon: the accent when its destination is
/// showing, the resting colour otherwise. Works in every theme because the
/// accent is lime in Verdant Night and green elsewhere.
Color _iconActiveColor(AppThemeData theme, bool active) {
  if (!active) {
    return theme.usesModernDesign ? theme.iconDefault : theme.textSecondary;
  }
  return theme.accent;
}

class DesktopTitleBar extends ConsumerStatefulWidget {
  // Matches the shell's centre-view constants. Friends is not among them: it
  // is a side panel now, tracked by [friendsPanelOpen] instead.
  final int currentView; // 0=home, 1=search, 2=playlist, 3=settings, 4=friend
  final VoidCallback? onSearchTap; // kept for compatibility (unused internally)
  final void Function(String query)? onSearch;
  final VoidCallback? onHome;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  /// Opens the account dropdown. Receives the avatar's bottom-right corner in
  /// global coordinates so the shell can anchor the menu under it.
  final void Function(Offset avatarBottomRight)? onProfileTap;

  final VoidCallback? onFriendsTap;

  /// Whether the friend activity panel is currently showing in the right-hand
  /// column — the friends icon highlights while it is open.
  final bool friendsPanelOpen;

  final VoidCallback? onSettingsTap;
  final bool canGoBack;
  final bool canGoForward;

  /// Called when the user submits a query or taps a recent search —
  /// the shell uses this to switch to DesktopSearchView (view 1).
  final void Function(String query)? onNavigateToSearch;

  const DesktopTitleBar({
    super.key,
    this.currentView = 0,
    this.onSearchTap,
    this.onSearch,
    this.onHome,
    this.onBack,
    this.onForward,
    this.onProfileTap,
    this.onFriendsTap,
    this.friendsPanelOpen = false,
    this.onSettingsTap,
    this.canGoBack = false,
    this.canGoForward = false,
    this.onNavigateToSearch,
  });

  @override
  ConsumerState<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends ConsumerState<DesktopTitleBar> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final LayerLink _searchLink = LayerLink();
  final OverlayPortalController _searchOverlayController =
      OverlayPortalController();

  /// Locates the account avatar so the menu can be anchored under it.
  final GlobalKey _avatarKey = GlobalKey();

  Timer? _suggestionTimer;
  bool _searchExpanded = false;

  // ── Maximum suggestions shown in the popup ─────────────────────────────────
  static const int _kMaxSuggestions = 8;
  static const int _kMaxArtists = 4;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    _searchFocus.removeListener(_onSearchFocusChanged);
    _suggestionTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;
    setState(() => _searchExpanded = _searchFocus.hasFocus);
    if (_searchFocus.hasFocus) {
      _searchOverlayController.show();
    } else {
      // Small delay so tap events on the dropdown are processed first.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_searchFocus.hasFocus) {
          _searchOverlayController.hide();
          setState(() => _searchExpanded = false);
        }
      });
    }
  }

  // ── Closes popup and unfocuses the field ───────────────────────────────────
  void _closePopup() {
    _suggestionTimer?.cancel();
    _searchOverlayController.hide();
    _searchFocus.unfocus();
    setState(() => _searchExpanded = false);
  }

  // ── Enter / onSubmitted ────────────────────────────────────────────────────
  // Saves query to history, triggers search in the provider (so the search
  // view has results immediately), closes popup, and navigates to view 1.
  void _submitSearch([String? value]) {
    final query = (value ?? _searchController.text).trim();
    if (query.isEmpty) return;
    _suggestionTimer?.cancel();

    // Keep field text intact
    _searchController
      ..text = query
      ..selection = TextSelection.collapsed(offset: query.length);

    // Save to history
    ref.read(searchHistoryProvider.notifier).addQuery(query);
    // Kick off the search so DesktopSearchView is pre-populated
    ref.read(searchProvider.notifier).search(query);

    _closePopup();

    // Navigate to search view
    widget.onNavigateToSearch?.call(query);
    // Legacy callback kept for compatibility
    widget.onSearch?.call(query);
  }

  // ── Suggestion typing ──────────────────────────────────────────────────────
  void _onSearchChanged(String value) {
    setState(() {});
    _suggestionTimer?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      ref.read(searchProvider.notifier).clear();
      return;
    }
    // 300 ms debounce
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _searchFocus.hasFocus) {
        ref.read(searchProvider.notifier).search(query);
      }
    });
  }

  // ── Clicking a recent search ───────────────────────────────────────────────
  // Fills the field and navigates to the search view (same as pressing Enter).
  void _selectHistory(String query) {
    _suggestionTimer?.cancel();
    _searchController
      ..text = query
      ..selection = TextSelection.collapsed(offset: query.length);

    // Save (moves it to top if already present)
    ref.read(searchHistoryProvider.notifier).addQuery(query);
    // Pre-populate results
    ref.read(searchProvider.notifier).search(query);

    _closePopup();

    // Navigate to search view
    widget.onNavigateToSearch?.call(query);
    widget.onSearch?.call(query);
  }

  // ── Clicking a song suggestion ─────────────────────────────────────────────
  // Plays the song directly — does NOT navigate to the search page.
  void _playSuggestion(String searchQuery) {
    // Optionally add to history
    ref.read(searchHistoryProvider.notifier).addQuery(searchQuery);
    _closePopup();
    // (actual play call is made inline in the list tile's onTap)
  }

  // ── Escape key ────────────────────────────────────────────────────────────
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closePopup();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final guestMode = ref.watch(guestSessionProvider);
    final theme = context.appTheme;
    final currentUser = ref.watch(authStateProvider).asData?.value;

    return Container(
      height: theme.layout.topBarHeight,
      color: theme.sidebar,
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // ── Left: nav controls ─────────────────────────────────────────
          _navBtn(
            Icons.arrow_back_ios_new,
            size: 16,
            enabled: widget.canGoBack,
            onPressed: widget.onBack,
            theme: theme,
          ),
          SizedBox(width: 4),
          _navBtn(
            Icons.arrow_forward_ios,
            size: 16,
            enabled: widget.canGoForward,
            onPressed: widget.onForward,
            theme: theme,
          ),

          // ── Center: home + search ──────────────────────────────────────
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _iconBtn(
                  Icons.home,
                  color: _iconActiveColor(
                      theme, widget.currentView == _kViewHome),
                  onPressed: widget.onHome,
                  tooltip: 'Home',
                ),
                SizedBox(width: 8),
                _buildSearchField(theme),
              ],
            ),
          ),

          // ── Right: notifications + friends + avatar ───────────────────
          if (!guestMode) ...[
            const NotificationsButton(),
            SizedBox(width: 4),
            // Toggles the friend activity panel in the right-hand column, so
            // its "active" state is the panel being open, not a centre view.
            _iconBtn(
              Icons.people_outline,
              color: _iconActiveColor(theme, widget.friendsPanelOpen),
              onPressed: widget.onFriendsTap,
              tooltip: widget.friendsPanelOpen ? 'Close friends' : 'Friends',
            ),
            // No settings gear here any more — Settings lives in the account
            // menu (tap the avatar).
            SizedBox(width: 8),
          ],
          Tooltip(
            message: 'Edit profile and account',
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () {
                // Hand the shell the avatar's bottom-right corner so it can hang
                // the account menu directly under it. A GlobalKey rather than
                // the surrounding context, which would measure the whole bar.
                final box = _avatarKey.currentContext?.findRenderObject()
                    as RenderBox?;
                final anchor = box == null
                    ? Offset.zero
                    : box.localToGlobal(box.size.bottomRight(Offset.zero));
                widget.onProfileTap?.call(anchor);
              },
              child: Padding(
                key: _avatarKey,
                padding: EdgeInsets.all(2),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: theme.cardColor,
                  child: currentUser?.photoURL?.isNotEmpty == true
                      ? ClipOval(
                          child: Image.network(
                            currentUser!.photoURL!,
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.person,
                              color: theme.textSecondary,
                              size: 18,
                            ),
                          ),
                        )
                      : Icon(Icons.person,
                          color: theme.textSecondary, size: 18),
                ),
              ),
            ),
          ),
          SizedBox(width: 8),
        ],
      ),
    );
  }

  // ── Search field + overlay portal ──────────────────────────────────────────
  Widget _buildSearchField(DesktopStyle theme) {
    return Focus(
      onKeyEvent: _onKey,
      child: OverlayPortal(
        controller: _searchOverlayController,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _searchLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 6),
          child: Align(
            alignment: Alignment.topLeft,
            child: _buildSearchDropdown(theme),
          ),
        ),
        child: SizedBox(
          width: 340,
          child: CompositedTransformTarget(
            link: _searchLink,
            child: Container(
              height: theme.layout.searchHeight,
              decoration: BoxDecoration(
                color: theme.usesModernDesign
                    ? theme.highlightElevated
                    : theme.cardColor,
                borderRadius: BorderRadius.circular(
                  theme.usesModernDesign
                      ? theme.layout.searchRadius
                      : (_searchExpanded ? 8 : 999),
                ),
                border: _searchExpanded
                    ? Border.all(
                        color: theme.nowPlayingAccent,
                        width: 1.5,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  SizedBox(width: 12),
                  Icon(Icons.search, color: theme.textSecondary, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      style: TextStyle(color: theme.textPrimary, fontSize: 14),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'What do you want to play?',
                        hintStyle:
                            TextStyle(color: theme.textSecondary, fontSize: 14),
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: _onSearchChanged,
                      onSubmitted: _submitSearch,
                    ),
                  ),
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.close,
                          color: theme.textSecondary, size: 17),
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 30, minHeight: 30),
                      onPressed: _clearSearch,
                    ),
                  SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── X button: clear text, clear suggestions, keep popup open with history ──
  void _clearSearch() {
    _suggestionTimer?.cancel();
    _searchController.clear();
    ref.read(searchProvider.notifier).clear();
    // Re-focus so the popup stays open showing recent searches
    _searchFocus.requestFocus();
    _searchOverlayController.show();
    setState(() {});
  }

  Widget _dropdownLabel(DesktopStyle theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          text,
          style: TextStyle(
              color: theme.nowPlayingAccent, fontWeight: FontWeight.w700),
        ),
      );

  // ── Dropdown panel ─────────────────────────────────────────────────────────
  Widget _buildSearchDropdown(DesktopStyle theme) {
    final history = ref.watch(searchHistoryProvider);
    final searchState = ref.watch(searchProvider);

    // Cap suggestions to _kMaxSuggestions
    final suggestions = searchState.results.take(_kMaxSuggestions).toList();

    // Artists come from the same mixed YouTube Music lookup the search view
    // uses, so the dropdown can offer them above the songs Spotify-style.
    final committed = searchState.query.trim();
    final extras = committed.isEmpty
        ? null
        : ref.watch(ytSearchAllProvider(committed)).valueOrNull;
    final artists =
        extras?.artists.take(_kMaxArtists).toList() ?? const <YtArtist>[];

    final hasResults = searchState.query.isNotEmpty &&
        (suggestions.isNotEmpty || artists.isNotEmpty);

    Widget content;

    if (searchState.isLoading) {
      content = Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              // Every other spinner in the desktop tree drops to subtext in
              // Verdant Night; this was the last one on the bright accent.
              color: theme.usesModernDesign ? theme.subtext : theme.accent,
            ),
          ),
        ),
      );
    } else if (hasResults) {
      // ── Suggestions list ─────────────────────────────────────────────
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (artists.isNotEmpty) ...[
            _dropdownLabel(theme, 'Artists'),
            for (final artist in artists)
              _ArtistSuggestionTile(
                artist: artist,
                theme: theme,
                onTap: () {
                  _closePopup();
                  openArtistPage(context, ref, artist.browseId);
                },
              ),
          ],
          if (suggestions.isNotEmpty) ...[
            _dropdownLabel(theme, artists.isEmpty ? 'Suggestions' : 'Songs'),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: 8),
              itemCount: suggestions.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: theme.usesModernDesign
                    ? theme.dividerColor
                    : theme.textSecondary.withValues(alpha: 0.1),
              ),
              itemBuilder: (_, i) {
                final song = suggestions[i];
                return _SuggestionTile(
                  song: song,
                  theme: theme,
                  onTap: () {
                    // Play directly — do NOT navigate to search view
                    ref.read(playerProvider.notifier).playSong(
                          song,
                          queue: suggestions,
                        );
                    _playSuggestion(_searchController.text.trim());
                  },
                );
              },
            ),
          ],
        ],
      );
    } else if (searchState.query.isNotEmpty && searchState.error != null) {
      content = Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          searchState.error!,
          style: TextStyle(color: theme.textSecondary),
        ),
      );
    } else if (searchState.query.isNotEmpty && !searchState.isLoading) {
      content = Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'No suggestions found',
          style: TextStyle(color: theme.textSecondary),
        ),
      );
    } else if (history.isEmpty) {
      content = Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'Search for songs, artists, or videos',
          style: TextStyle(color: theme.textSecondary),
        ),
      );
    } else {
      // ── Recent searches ──────────────────────────────────────────────
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: [
                Text(
                  'Recent searches',
                  style: TextStyle(
                      color: theme.nowPlayingAccent,
                      fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      ref.read(searchHistoryProvider.notifier).clearHistory(),
                  child: Text(
                    'Clear',
                    style: TextStyle(color: theme.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: history.length,
            itemBuilder: (_, i) {
              final query = history[i];
              return ListTile(
                dense: true,
                leading:
                    Icon(Icons.history, color: theme.textSecondary, size: 20),
                title: Text(
                  query,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textPrimary),
                ),
                trailing: Icon(Icons.north_west,
                    color: theme.textSecondary, size: 16),
                onTap: () => _selectHistory(query),
              );
            },
          ),
        ],
      );
    }

    // Wrap in a scrollable, constrained container
    return Material(
      color: theme.cardColor,
      elevation: 12,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        // Match the search field width
        width: 340,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: content,
          ),
        ),
      ),
    );
  }

  // ── Icon helpers ────────────────────────────────────────────────────────────

  Widget _navBtn(
    IconData icon, {
    double size = 20,
    bool enabled = true,
    VoidCallback? onPressed,
    required DesktopStyle theme,
  }) {
    return IconButton(
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        color: enabled
            ? (theme.usesModernDesign
                ? theme.iconDefault
                : theme.textPrimary)
            : theme.textSecondary.withValues(alpha: 0.4),
        size: size,
      ),
      splashRadius: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }

  Widget _iconBtn(
    IconData icon, {
    Color? color,
    double size = 20,
    VoidCallback? onPressed,
    String? tooltip,
  }) {
    final theme = context.appTheme;
    return IconButton(
      onPressed: onPressed ?? () {},
      // Explicit colour always wins. Callers pass iconDefault in Verdant Night
      // when they want the resting look, which is what this used to hardcode —
      // but that also meant an "active" accent could never be shown in that
      // theme. Same result for every caller that passes a colour today.
      icon: Icon(icon, color: color ?? theme.iconDefault, size: size),
      splashRadius: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: tooltip,
    );
  }
}

// ─── Suggestion tile ──────────────────────────────────────────────────────────

class _SuggestionTile extends StatefulWidget {
  final Song song;
  final DesktopStyle theme;
  final VoidCallback onTap;

  const _SuggestionTile({
    required this.song,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_SuggestionTile> createState() => _SuggestionTileState();
}

class _SuggestionTileState extends State<_SuggestionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final theme = widget.theme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          color: _hovered
              ? theme.textSecondary.withValues(alpha: 0.08)
              : context.appTheme.main.withValues(alpha: 0),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: song.thumbnailUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: song.thumbnailUrl,
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          width: 36,
                          height: 36,
                          color: theme.cardColor,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 36,
                          height: 36,
                          color: theme.cardColor,
                          child: Icon(Icons.music_note,
                              color: context.appTheme.subtext
                                  .withValues(alpha: 0.54),
                              size: 16),
                        ),
                      )
                    : Container(
                        width: 36,
                        height: 36,
                        color: theme.cardColor,
                        child: Icon(Icons.music_note,
                            color: theme.textSecondary, size: 16),
                      ),
              ),
              SizedBox(width: 10),
              // Title + channel
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    SizedBox(height: 2),
                    ArtistNames(
                      refs: song.artistRefs,
                      fallbackName: song.channelName,
                      maxLines: 1,
                      style:
                          TextStyle(color: theme.textSecondary, fontSize: 11),
                      hoverStyle: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 11,
                          decoration: TextDecoration.underline,
                          decorationColor: theme.textPrimary),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8),
              Icon(Icons.play_arrow, color: theme.accent, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Artist suggestion tile ───────────────────────────────────────────────────

/// A round-avatar artist row in the search dropdown. Tapping it opens the
/// artist's YouTube Music page — the same destination the search view's artist
/// cards use.
class _ArtistSuggestionTile extends StatefulWidget {
  final YtArtist artist;
  final DesktopStyle theme;
  final VoidCallback onTap;

  const _ArtistSuggestionTile({
    required this.artist,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_ArtistSuggestionTile> createState() => _ArtistSuggestionTileState();
}

class _ArtistSuggestionTileState extends State<_ArtistSuggestionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final theme = widget.theme;

    Widget fallback() => Container(
          width: 36,
          height: 36,
          color: theme.cardColor,
          child: Icon(Icons.person, color: theme.textSecondary, size: 16),
        );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          color: _hovered
              ? theme.textSecondary.withValues(alpha: 0.08)
              : context.appTheme.main.withValues(alpha: 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ClipOval(
                child: artist.pictureUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: artist.pictureUrl,
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => fallback(),
                        errorWidget: (_, __, ___) => fallback(),
                      )
                    : fallback(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text('Artist',
                        style:
                            TextStyle(color: theme.textSecondary, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.person_outline, color: theme.textSecondary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
