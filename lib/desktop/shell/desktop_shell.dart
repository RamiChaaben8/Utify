// ============================================================
// desktop/shell/desktop_shell.dart
// Main 3-column layout shell for Windows.
// ============================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import 'desktop_navigation.dart';
import '../../providers/local_music_provider.dart';
import '../../services/download_index_service.dart';

import '../../providers/panel_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/presence_provider.dart';
import '../../providers/youtube_provider.dart';
import '../../providers/friends_provider.dart';
import '../../providers/guest_session_provider.dart';
// Also provides Playlist.firestoreId (the Expando-backed extension), which the
// view history and sidebar keys compare on.
import '../../services/firestore_service.dart';
import '../home/desktop_home_view.dart';
import '../home/desktop_yt_album_view.dart';
import '../now_playing/desktop_now_playing_panel.dart';
import '../player/desktop_player_bar.dart';
import '../player/lyrics_panel.dart';
import '../player/queue_panel.dart';
import '../playlist/desktop_playlist_view.dart';
import '../sidebar/desktop_sidebar.dart';
import '../shell/panel_widths.dart';
import '../theme/desktop_theme.dart';
import '../desktop_search_view.dart';
import 'desktop_title_bar.dart';
import '../../widgets/remote_playback_banner.dart';
import '../../widgets/offline_indicator.dart';
import '../friends/desktop_friends_panel.dart';
import '../friends/desktop_friend_profile_view.dart';
import '../settings/desktop_settings_view.dart';
import '../views/downloads_view.dart';

import '../../widgets/update_dialog.dart';
import '../../services/taskbar_controls.dart';

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell>
    with WidgetsBindingObserver {
  /// Centre-view indices.
  ///
  /// Named because the shell refers to these from the history stack, the title
  /// bar's active-icon logic, the settings gear and the playlist-request
  /// listener. Friends used to be a centre view too; when it moved into the
  /// right-hand panel the indices shifted, and bare ints made that a
  /// renumbering trap.
  static const int _viewHome = 0;
  static const int _viewSearch = 1;
  static const int _viewPlaylist = 2;
  static const int _viewSettings = 3;
  static const int _viewFriendProfile = 4;
  static const int _viewYtAlbum = 5;
  static const int _viewDownloads = 6;

  final List<int> _history = [_viewHome];
  int _historyIndex = 0;
  Playlist? _viewedPlaylist;
  String? _viewedYtBrowseId;

  /// The friend whose profile [_viewFriendProfile] is showing.
  PublicProfile? _viewedFriendProfile;

  /// Which settings category the rail should open on. Held here rather than
  /// inside the view so the account menu's "Profile" and "Settings" entries
  /// can land on different categories of the same view.
  SettingsSection _settingsSection = SettingsSection.appearance;

  /// Spotify-style draggable widths for the sidebar and the right-hand panel.
  final PanelWidthStore _panelWidths = PanelWidthStore();

  int get _currentView => _history[_historyIndex];
  bool get _canGoBack => _historyIndex > 0;
  bool get _canGoForward => _historyIndex < _history.length - 1;

  void _navigateTo(int view,
      {Playlist? playlist, PublicProfile? friendProfile,
      String? ytBrowseId}) {
    if (_currentView == view &&
        (view != _viewPlaylist ||
            _isSamePlaylist(_viewedPlaylist, playlist)) &&
        (view != _viewFriendProfile ||
            _viewedFriendProfile?.uid == friendProfile?.uid) &&
        (view != _viewYtAlbum ||
            _viewedYtBrowseId == ytBrowseId)) {
      return;
    }
    setState(() {
      _history.removeRange(_historyIndex + 1, _history.length);
      _history.add(view);
      _historyIndex = _history.length - 1;
      if (view == _viewPlaylist) {
        _viewedPlaylist = playlist;
      }
      if (view == _viewFriendProfile) {
        _viewedFriendProfile = friendProfile;
      }
      if (view == _viewYtAlbum) {
        _viewedYtBrowseId = ytBrowseId;
      }
    });
  }

  /// Returns true if [a] and [b] refer to the same playlist.
  bool _isSamePlaylist(Playlist? a, Playlist? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    final aFsId = a.firestoreId;
    final bFsId = b.firestoreId;
    if (aFsId != null && bFsId != null) return aFsId == bFsId;
    final aKey = a.key;
    final bKey = b.key;
    if (aKey != null && bKey != null) return aKey == bKey;
    return a.name == b.name && a.createdAt == b.createdAt;
  }

  void _goBack() {
    if (!_canGoBack) return;
    setState(() => _historyIndex--);
  }

  void _goForward() {
    if (!_canGoForward) return;
    setState(() => _historyIndex++);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _panelWidths.addListener(_onPanelWidthsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(localMusicProvider.notifier).scan();
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) {
        ref.read(friendsProvider.notifier).initForUser(uid);
        ref.read(presenceProvider.notifier).start(
              uid,
              playerState: ref.read(playerProvider),
            );
      }

      // Initialise Windows taskbar thumbnail toolbar (Prev / Play-Pause / Next).
      // Must be called after the first frame so the native window handle exists.
      TaskbarControls.instance.init(
        onPrev: () => ref.read(playerProvider.notifier).skipToPrevious(),
        onPlayPause: () => ref.read(playerProvider.notifier).togglePlayPause(),
        onNext: () => ref.read(playerProvider.notifier).skipToNext(),
      );
      TaskbarControls.instance
          .updatePlayState(ref.read(playerProvider).isPlaying);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _panelWidths
      ..removeListener(_onPanelWidthsChanged)
      ..dispose();
    super.dispose();
  }

  void _onPanelWidthsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Each theme remembers its own panel widths, so swap them on theme change.
    _panelWidths.bindTheme(context.appTheme.name);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(localMusicProvider.notifier).scan();
      DownloadIndexService.instance.runStartupMaintenance();
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) {
        ref.read(presenceProvider.notifier).start(
              uid,
              playerState: ref.read(playerProvider),
            );
      }
    }
    // Saving is enough when Windows hides/minimizes the window. Playback must
    // continue so the desktop app behaves like a background music player.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      ref.read(playerProvider.notifier).saveSession().catchError((_) {});
    }
    // Release active-device claim when app is fully closed so another
    // device can auto-claim on next launch.
    if (state == AppLifecycleState.detached) {
      ref.read(presenceProvider.notifier).stop();
      ref.read(playerProvider.notifier).saveSession().catchError((_) {});
      ref.read(playerProvider.notifier).pauseLocal();
      ref
          .read(syncProvider.notifier)
          .service
          .releaseIfActive()
          .catchError((_) {});
      ref
          .read(syncProvider.notifier)
          .service
          .unregisterCurrentDevice()
          .catchError((_) {});
    }
  }

  /// Opens the account dropdown under the top-right avatar.
  ///
  /// [anchor] is the avatar's bottom-right corner in global coordinates. It was
  /// a centred `AlertDialog` before: a modal card floating in the middle of the
  /// window, with the email and current theme as ListTile subtitles. This is the
  /// Spotify shape â€” a right-aligned menu hanging off the avatar, one label per
  /// row. `showMenu` gives us the modal barrier and Esc handling for free.
  Future<void> _showAccountMenu(Offset anchor) async {
    if (ref.read(guestSessionProvider)) {
      final shouldSignIn = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: dialogContext.appTheme.card,
          title: Text('Guest mode',
              style: TextStyle(color: dialogContext.appTheme.text)),
          content: Text(
              'Would you like to leave guest mode and go to the sign-in page?',
              style: TextStyle(color: dialogContext.appTheme.subtext)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Stay as guest')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Go to sign in')),
          ],
        ),
      );
      if (shouldSignIn == true) {
        await ref.read(guestSessionProvider.notifier).leaveGuest();
      }
      return;
    }

    final action = await showMenu<_AccountAction>(
      context: context,
      // Left edge back by the menu width puts its right edge under the avatar's
      // right edge; top = the avatar's bottom, so it opens downwards.
      position: RelativeRect.fromLTRB(
        anchor.dx - _kAccountMenuWidth,
        anchor.dy,
        anchor.dx,
        anchor.dy + 1,
      ),
      color: context.appTheme.card,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      items: _accountMenuEntries(),
    );

    if (!mounted || action == null) return;
    if (action == _AccountAction.signOut) {
      await ref.read(playerProvider.notifier).pause().catchError((_) {});
      await ref.read(authServiceProvider).signOut();
    } else if (action == _AccountAction.checkForUpdates) {
      if (mounted) await showUpdateDialog(context, ref);
    } else if (action == _AccountAction.profile) {
      _openSettings(SettingsSection.profile);
    } else if (action == _AccountAction.appearance) {
      _openSettings(SettingsSection.appearance);
    } else {
      // Opens the settings pane on Privacy rather than pushing the mobile
      // privacy screen as a route over the whole shell.
      _openSettings(SettingsSection.privacy);
    }
  }

  /// Exactly the five entries the account dialog had. The Theme picker itself
  /// lives in Settings â†’ Appearance, so "Theme" is a way in, not a second
  /// control.
  List<PopupMenuEntry<_AccountAction>> _accountMenuEntries() {
    final theme = context.appTheme;
    return [
      _accountEntry(Icons.person_outline, 'Profile', _AccountAction.profile),
      _accountEntry(
          Icons.palette_outlined, 'Theme', _AccountAction.appearance),
      _accountEntry(
          Icons.settings_outlined, 'Settings', _AccountAction.settings),
      _accountEntry(Icons.system_update_alt, 'Check for Updates',
          _AccountAction.checkForUpdates),
      // Thin rule separating ordinary entries from the destructive one.
      PopupMenuItem<_AccountAction>(
        enabled: false,
        height: 1,
        padding: EdgeInsets.zero,
        child: Divider(color: theme.dividerColor, height: 1, thickness: 0.5),
      ),
      _accountEntry(Icons.logout, 'Sign out', _AccountAction.signOut,
          color: theme.notificationError),
    ];
  }

  /// Flat icon + label row, ~40px tall, label left-aligned.
  PopupMenuItem<_AccountAction> _accountEntry(
    IconData icon,
    String label,
    _AccountAction value, {
    Color? color,
  }) {
    final theme = context.appTheme;
    final foreground = color ?? theme.text;
    return PopupMenuItem<_AccountAction>(
      value: value,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? theme.iconDefault),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foreground, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  /// Only one right-hand panel at a time: opening friends puts the queue and
  /// Now Playing away, and closing it brings Now Playing back.
  void _toggleFriendsPanel() {
    ref.read(panelModeProvider.notifier).state =
        ref.read(panelModeProvider) == PanelMode.friends
            ? PanelMode.none
            : PanelMode.friends;
  }

  void _closeRightPanel() {
    if (ref.read(panelModeProvider) == PanelMode.none) return;
    ref.read(panelModeProvider.notifier).state = PanelMode.none;
  }

  void _openSettings(SettingsSection section) {
    // Settings covers the whole window, so any panel that was open (lyrics is a
    // full-screen overlay, queue/now-playing live in the right-hand column) has
    // to be put away or it would still be drawn over the page.
    if (ref.read(panelModeProvider) != PanelMode.none) {
      ref.read(panelModeProvider.notifier).state = PanelMode.none;
    }
    setState(() => _settingsSection = section);
    _navigateTo(_viewSettings);
  }

  /// The gear doubles as the way out: settings is the only view that can hide
  /// the player bar, so tapping it again should restore the shell.
  void _toggleSettings() {
    if (_currentView != _viewSettings) {
      _openSettings(SettingsSection.appearance);
      return;
    }
    _backOrHome();
  }

  /// Back that cannot become a dead end. The friend profile is reachable from
  /// the side panel without touching the centre column, so its Back link has to
  /// cope with no history behind it.
  void _backOrHome() {
    if (_canGoBack) {
      _goBack();
    } else {
      _navigateTo(_viewHome);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerState>(playerProvider, (_, next) {
      ref.read(presenceProvider.notifier).updateFromPlayer(next);
      // Keep taskbar Play/Pause icon in sync with actual playback state.
      TaskbarControls.instance.updatePlayState(next.isPlaying);
    });

    // Surfaces without a direct sidebar handle ask for the centre view this way
    // â€” the friend profile's playlist grid, and the friend activity panel's
    // "Open profile" entry. Routed through _navigateTo so the view history and
    // the back button stay correct, then cleared so a rebuild doesn't reopen it.
    ref.listen<Playlist?>(desktopPlaylistRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(desktopPlaylistRequestProvider.notifier).state = null;
      _navigateTo(_viewPlaylist, playlist: next);
    });
    ref.listen<PublicProfile?>(desktopFriendProfileRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(desktopFriendProfileRequestProvider.notifier).state = null;
      _navigateTo(_viewFriendProfile, friendProfile: next);
    });
    ref.listen<String?>(desktopYtBrowseRequestProvider, (_, next) {
      if (next == null || next.isEmpty) return;
      ref.read(desktopYtBrowseRequestProvider.notifier).state = null;
      _navigateTo(_viewYtAlbum, ytBrowseId: next);
    });
    final panelMode = ref.watch(panelModeProvider);
    final guestMode = ref.watch(guestSessionProvider);

    // Settings is a whole-window page, not a centre view: the library rail, the
    // now-playing/lyrics/queue panel and the player bar are all suppressed so
    // nothing competes with the form. Playback keeps running underneath â€” the
    // bar is just not drawn.
    final fullScreenSettings = _currentView == _viewSettings;

    return Scaffold(
      backgroundColor: context.appTheme.main,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wideEnough = constraints.maxWidth >= 1100;
          final layout = context.appTheme.layout;
          final screenW = constraints.maxWidth;

          // â”€â”€ Panel widths (Spotify-style, user draggable) â”€â”€â”€â”€â”€â”€â”€â”€â”€
          // Each panel may grow up to its own limit, but never far enough to
          // squeeze the centre view out of the window.
          final gapTotal = layout.panelGap * (wideEnough ? 2 : 1);
          final sidebarBase = resolvePanelWidth(
            layout: layout,
            screenWidth: screenW,
            override: _panelWidths.sidebar,
            isNowPlaying: false,
          );
          final nowPlayingBase = resolvePanelWidth(
            layout: layout,
            screenWidth: screenW,
            override: _panelWidths.nowPlaying,
            isNowPlaying: true,
          );
          // A width saved on a wider window must not squeeze the centre view
          // out of a narrower one, so cap what is actually rendered by what the
          // current window can spare. The stored width is left untouched, so
          // the panel springs back once the window is wide enough again.
          final maxSidebar = math.min(
            kSidebarResizeMax,
            math.max(
              kSidebarResizeMin,
              screenW - gapTotal - kCenterMinWidth - nowPlayingBase,
            ),
          );
          final maxNowPlaying = math.min(
            kNowPlayingResizeMax,
            math.max(
              kNowPlayingResizeMin,
              screenW - gapTotal - kCenterMinWidth - sidebarBase,
            ),
          );
          final sidebarCollapsed = _panelWidths.sidebar != null &&
              _panelWidths.sidebar! <= kSidebarCollapsed;

          // The collapsed rail has a fixed width and must not be clamped back
          // up to the minimum expanded width.
          final sidebarW = sidebarCollapsed
              ? kSidebarCollapsedWidth
              : sidebarBase.clamp(kSidebarResizeMin, maxSidebar);
          final nowPlayingW =
              nowPlayingBase.clamp(kNowPlayingResizeMin, maxNowPlaying);

          // Full-screen lyrics overlay sits on top of the entire shell
          // (above the player bar too) when PanelMode.lyrics is active.
          final shell = Column(
            children: [
              // â”€â”€ Title bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              DesktopTitleBar(
                currentView: _currentView,
                canGoBack: _canGoBack,
                canGoForward: _canGoForward,
                onBack: _goBack,
                onForward: _goForward,
                onHome: () => _navigateTo(_viewHome),
                onSearchTap: () => _navigateTo(_viewSearch),
                onSearch: (q) {
                  ref.read(searchProvider.notifier).search(q);
                },
                // Called when user presses Enter or taps a recent search â€”
                // the provider search is already fired inside the title bar,
                // so we only need to navigate here.
                onNavigateToSearch: (q) => _navigateTo(_viewSearch),
                onProfileTap: _showAccountMenu,
                // Friend activity lives in the right-hand column now, so this
                // toggles that panel instead of replacing the centre view. The
                // icon highlights while it is open.
                friendsPanelOpen: panelMode == PanelMode.friends,
                onFriendsTap: guestMode ? null : _toggleFriendsPanel,
                // Appearance works without an account, so the gear stays live
                // in guest mode â€” Profile/Privacy simply explain why they
                // can't be changed.
                onSettingsTap: _toggleSettings,
              ),

              // Settings is a whole-window page: everything below the title bar
              // â€” library rail, now-playing/lyrics/queue panel, player bar â€”
              // is replaced by the settings surface. Playback keeps running
              // underneath; the bar simply is not drawn.
              if (fullScreenSettings)
                Expanded(child: _buildCenterView())
              else ...[
                // â”€â”€ Main content row â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DesktopSidebar(
                        width: sidebarW,
                        collapsed: sidebarCollapsed,
                        onCollapsedChanged: (c) => _panelWidths.setSidebar(
                            c ? kSidebarCollapsed : null),
                        selectedPlaylist:
                            _currentView == _viewPlaylist
                                ? _viewedPlaylist
                                : null,
                        onPlaylistSelected: (p) {
                          if (p != null) {
                            _navigateTo(_viewPlaylist, playlist: p);
                          } else {
                            _navigateTo(_viewHome);
                          }
                        },
                         onDownloadsSelected: () => _navigateTo(_viewDownloads),
                      ),
                      // Drag the divider to resize the sidebar. Dragging past the
                      // minimum expanded width snaps it to the icon rail, and
                      // dragging back out expands it again.
                      SizedBox(
                        width: layout.panelGap,
                        child: PanelResizeHandle(
                          onLeftEdge: false,
                          min: kSidebarCollapsed,
                          max: maxSidebar,
                          value: sidebarW,
                          onChanged: (w) =>
                              _panelWidths.setSidebar(storedSidebarWidth(w)),
                          onReset: () => _panelWidths.setSidebar(null),
                        ),
                      ),
                      Expanded(
                        child: ClipRect(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _buildCenterView(),
                          ),
                        ),
                      ),
                      // Right panel â€” one of Now Playing / Queue / Friend activity.
                      // LyricsPanel is a separate fullscreen overlay (below).
                      if (wideEnough) ...[
                        // Drag the divider to resize the video + lyrics card panel.
                        SizedBox(
                          width: layout.panelGap,
                          child: PanelResizeHandle(
                            onLeftEdge: true,
                            min: kNowPlayingResizeMin,
                            max: maxNowPlaying,
                            value: nowPlayingW,
                            onChanged: _panelWidths.setNowPlaying,
                            onReset: () => _panelWidths.setNowPlaying(null),
                          ),
                        ),
                        Stack(
                          children: [
                            // Friends is built only while it is open, unlike the
                            // queue/now-playing pair below which stay alive
                            // offstage so opening the queue does not re-fetch
                            // anything. Friend activity polls Firestore on a
                            // timer, and that should not run behind a panel
                            // nobody can see.
                            if (panelMode == PanelMode.friends)
                              DesktopFriendsPanel(
                                key: const ValueKey('friends'),
                                width: nowPlayingW,
                                onClose: _closeRightPanel,
                              )
                            else ...[
                              Offstage(
                                offstage: panelMode != PanelMode.queue,
                                child: QueuePanel(
                                  key: const ValueKey('queue'),
                                  width: nowPlayingW,
                                  onClose: _closeRightPanel,
                                ),
                              ),
                              Offstage(
                                offstage: panelMode == PanelMode.queue,
                                child: DesktopNowPlayingPanel(
                                  key: const ValueKey('nowplaying'),
                                  width: nowPlayingW,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
  
                SizedBox(height: layout.panelGap),
  
                // â”€â”€ Offline indicator â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                const OfflineIndicator(),
  
                // â”€â”€ Player bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                const DesktopPlayerBar(),
              ],
            ],
          );

          // Always wrap in a Stack so the shell (and its VideoPreviewWidget)
          // is never disposed when the lyrics overlay opens/closes.
          // Using Offstage keeps the LyricsPanel in the tree but invisible
          // when not active, which also prevents it from re-fetching lyrics
          // on every open. We flip to visible only when lyrics mode is on.
          return Stack(
            children: [
              shell,
              // Cross-device banner (top of shell, below title bar)
              const Positioned(
                top: 40, // below title bar
                left: 0,
                right: 0,
                child: RemotePlaybackBanner(),
              ),
              // Never over the full-screen settings page â€” a lyrics overlay there would
              // hide the form the user just opened settings to reach.
              if (panelMode == PanelMode.lyrics && !fullScreenSettings)
                LyricsPanel(
                  key: const ValueKey('lyrics_overlay'),
                  onClose: _closeRightPanel,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCenterView() {
    switch (_currentView) {
      case _viewSearch:
        return const DesktopSearchView(key: ValueKey('search'));
      case _viewPlaylist:
        final p = _viewedPlaylist;
        if (p != null) {
          return DesktopPlaylistView(
            key: ValueKey('playlist_${p.firestoreId ?? p.key ?? p.name}'),
            playlist: p,
          );
        }

        return const DesktopHomeView(key: ValueKey('home'));
      case _viewSettings:
        return DesktopSettingsView(
          key: const ValueKey('settings'),
          // Re-entered from a different account-menu entry, so the rail starts
          // on whichever category the user asked for.
          initialSection: _settingsSection,
        );
      case _viewFriendProfile:
        final friend = _viewedFriendProfile;
        if (friend != null) {
          return DesktopFriendProfileView(
            key: ValueKey('friend_profile_${friend.uid}'),
            profile: friend,
            onBack: _backOrHome,
          );
        }
        return const DesktopHomeView(key: ValueKey('home'));
      case _viewYtAlbum:
        final bid = _viewedYtBrowseId;
        if (bid != null && bid.isNotEmpty) {
          return DesktopYtAlbumView(
            key: ValueKey('yt_album_$bid'),
            browseId: bid,
          );
        }
        return const DesktopHomeView(key: ValueKey('home'));
      case _viewDownloads:
        return const DownloadsView(key: ValueKey('downloads'));
      default:
        return const DesktopHomeView(key: ValueKey('home'));
    }
  }
}

/// Width of the account dropdown. Fixed rather than measured so
/// `showMenu`'s [RelativeRect] can right-align it against the avatar; the
/// longest row ("Check for Updates") sets the natural width anyway.
const double _kAccountMenuWidth = 220;

enum _AccountAction {
  profile,
  appearance,
  settings,
  signOut,
  checkForUpdates,
}
