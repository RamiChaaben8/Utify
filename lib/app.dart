// ============================================================
// app.dart — Root widget, theme, and navigation scaffold
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'providers/auth_provider.dart';
import 'dart:io';

import 'screens/search_screen.dart';
import 'screens/library_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/home_screen.dart';
import 'widgets/mini_player.dart';
import 'widgets/remote_playback_banner.dart';
import 'widgets/offline_indicator.dart';
import 'providers/player_provider.dart';
import 'providers/local_music_provider.dart';
import 'services/download_index_service.dart';

import 'providers/sync_provider.dart';
import 'providers/connectivity_provider.dart';

import 'providers/presence_provider.dart';
import 'providers/library_provider.dart';
import 'providers/listen_party_provider.dart';
import 'providers/guest_session_provider.dart';
import 'platform/permissions.dart';
import 'desktop/shell/desktop_shell.dart';
import 'desktop/theme/desktop_theme.dart';
import 'screens/auth/auth_gate.dart';

class TuneifyApp extends StatelessWidget {
  const TuneifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return AppThemeBuilder(
        builder: (context, theme) => MaterialApp(
          title: 'Utify',
          debugShowCheckedModeBanner: false,
          theme: _buildDesktopTheme(theme),
          builder: (context, child) => _MediaKeyListener(
            child: child ?? const SizedBox.shrink(),
          ),
          home: AuthGate(child: const DesktopShell()),
        ),
      );
    }
    return MaterialApp(
      title: 'Utify',
      debugShowCheckedModeBanner: false,
      theme: _buildDarkTheme(),
      builder: (context, child) => _MediaKeyListener(
        child: child ?? const SizedBox.shrink(),
      ),
      home: AuthGate(
        child: Platform.isWindows ? const DesktopShell() : const AppShell(),
      ),
    );
  }

  ThemeData _buildDesktopTheme(AppThemeData t) {
    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      scaffoldBackgroundColor: t.main,
      colorScheme: ColorScheme(
        brightness: t.brightness,
        primary: t.button,
        onPrimary: t.onButtonFill,
        secondary: t.buttonActive,
        onSecondary: t.onButtonFill,
        error: t.notificationError,
        onError: t.onErrorFill,
        surface: t.main,
        onSurface: t.text,
        // Without these, ColorScheme falls back to onSurface — which is LIME in
        // Verdant Night. That turned every ListTile subtitle, every Switch
        // off-thumb and every SnackBar slab into the accent colour.
        onSurfaceVariant: t.subtext,
        outline: t.subtext,
        inverseSurface: t.card,
        onInverseSurface: t.subtext,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: t.card,
        foregroundColor: t.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.card,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(color: t.subtext, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.card,
        contentTextStyle: TextStyle(color: t.subtext),
        actionTextColor: t.nowPlayingAccent,
        elevation: 6,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? t.onButtonFill : t.subtext),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? t.button : t.highlight),
        trackOutlineColor: WidgetStatePropertyAll(t.dividerColor),
      ),
      cardColor: t.card,
      dividerColor: t.dividerColor,
      textTheme: TextTheme(
        displayLarge: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        headlineLarge: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: t.text, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(color: t.text, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: t.text, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: t.text),
        bodyMedium: TextStyle(color: t.subtext),
        labelLarge: TextStyle(color: t.text, fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.card,
        hintStyle: TextStyle(color: t.subtext),
        border: const OutlineInputBorder(borderSide: BorderSide.none),
      ),
      iconTheme: IconThemeData(
          color: t.isVerdantNightDesktop ? t.iconDefault : t.text),
      iconButtonTheme: t.isVerdantNightDesktop
          ? IconButtonThemeData(style: t.iconButtonStyle)
          : const IconButtonThemeData(),
      tabBarTheme: t.isVerdantNightDesktop
          ? TabBarThemeData(
              labelColor: t.text,
              unselectedLabelColor: t.subtext,
              indicatorColor: t.text,
            )
          : const TabBarThemeData(),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: t.button),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.button,
        inactiveTrackColor: t.shadow,
        thumbColor: t.text,
        overlayColor: t.button.withValues(alpha: 0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
            t.isVerdantNightDesktop ? t.scrollbarThumbColor : t.button),
        thickness: const WidgetStatePropertyAll(4),
        radius: const Radius.circular(2),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    const bgColor = Color(0xFF0A0A0A);
    const surfaceColor = Color(0xFF121212);
    const cardColor = Color(0xFF1A1A1A);
    const accentGreen = Color(0xFF1DB954);
    const onSurface = Color(0xFFFFFFFF);
    const subtext = Color(0xFFB3B3B3);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgColor,
      colorScheme: const ColorScheme.dark(
        primary: accentGreen,
        secondary: accentGreen,
        surface: surfaceColor,
        onSurface: onSurface,
        onPrimary: Colors.black,
      ),
      cardColor: cardColor,
      dividerColor: const Color(0xFF282828),
      textTheme: TextTheme(
        displayLarge:
            const TextStyle(color: onSurface, fontWeight: FontWeight.bold),
        displayMedium:
            const TextStyle(color: onSurface, fontWeight: FontWeight.bold),
        headlineLarge:
            const TextStyle(color: onSurface, fontWeight: FontWeight.bold),
        headlineMedium:
            const TextStyle(color: onSurface, fontWeight: FontWeight.w700),
        titleLarge:
            const TextStyle(color: onSurface, fontWeight: FontWeight.w600),
        titleMedium:
            const TextStyle(color: onSurface, fontWeight: FontWeight.w500),
        bodyLarge: const TextStyle(color: onSurface),
        bodyMedium: const TextStyle(color: subtext),
        labelLarge:
            const TextStyle(color: onSurface, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: onSurface,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0D0D0D),
        indicatorColor: accentGreen.withOpacity(0.2),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
                color: accentGreen, fontSize: 12, fontWeight: FontWeight.w600);
          }
          return const TextStyle(color: subtext, fontSize: 12);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: accentGreen);
          }
          return const IconThemeData(color: subtext);
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        hintStyle: const TextStyle(color: subtext),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      iconTheme: const IconThemeData(color: onSurface),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: accentGreen),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentGreen,
        inactiveTrackColor: const Color(0xFF3A3A3A),
        thumbColor: Colors.white,
        overlayColor: accentGreen.withOpacity(0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
    );
  }
}

class _MediaKeyListener extends ConsumerStatefulWidget {
  final Widget child;

  const _MediaKeyListener({required this.child});

  @override
  ConsumerState<_MediaKeyListener> createState() => _MediaKeyListenerState();
}

class _MediaKeyListenerState extends ConsumerState<_MediaKeyListener> {
  final FocusNode _focusNode = FocusNode();
  static const _mediaKeyChannel = MethodChannel('com.tuneify/media_keys');

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _mediaKeyChannel.setMethodCallHandler(_handleGlobalMediaKey);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  Future<void> _handleGlobalMediaKey(MethodCall call) async {
    if (call.method != 'mediaKey' || call.arguments is! String) return;

    final player = ref.read(playerProvider.notifier);
    switch (call.arguments as String) {
      case 'playPause':
        await player.togglePlayPause();
        break;
      case 'stop':
        await player.stop();
        break;
      case 'next':
        await player.skipToNext();
        break;
      case 'previous':
        await player.skipToPrevious();
        break;
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final player = ref.read(playerProvider.notifier);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.mediaPlayPause:
        player.togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaStop:
        player.stop();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackNext:
        player.skipToNext();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackPrevious:
        player.skipToPrevious();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _mediaKeyChannel.setMethodCallHandler(null);
    }
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return widget.child;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }
}

// ─── App Shell (bottom nav + mini-player) ─────────────────────────────────
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  final Set<int> _visited = <int>{0};
  static const _androidLifecycleChannel =
      MethodChannel('com.example.testf/lifecycle');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Listen to connectivity changes and drive offline mode on SyncService.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(connectivityProvider, (prev, next) {
        final wasOnline = prev?.isOnline ?? true;
        final isOnline  = next.isOnline;
        final sync      = ref.read(syncProvider.notifier);
        sync.setOfflineMode(!isOnline);
        if (!wasOnline && isOnline) {
          // Reconnect: re-subscribe to Firestore; let remote state win.
          final isPlaying = ref.read(playerProvider).isPlaying;
          sync.reconnect(isActivelyPlaying: isPlaying).catchError((_) {});
          // Also refresh library from Firestore.
          final uid = ref.read(authServiceProvider).currentUser?.uid;
          if (uid != null) {
            ref.read(libraryProvider.notifier).initForUser(uid);
          }
        }
      }, fireImmediately: true);
    });

    if (Platform.isAndroid) {
      _androidLifecycleChannel.setMethodCallHandler((call) async {
        if (call.method == 'taskRemoved') {
          await ref.read(presenceProvider.notifier).stop();
          final sync = ref.read(syncProvider.notifier).service;
          await sync.releaseIfActive().catchError((_) {});
          await sync.unregisterCurrentDevice().catchError((_) {});
        }
      });
    }
    // Request storage permission then scan for local music on first frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestStoragePermission();
      if (mounted) {
        ref.read(localMusicProvider.notifier).scan();
        final uid = ref.read(authServiceProvider).currentUser?.uid;
        if (uid != null) {
          ref.read(presenceProvider.notifier).start(
                uid,
                playerState: ref.read(playerProvider),
              );
        }
      }
    });
  }

  Future<void> _requestStoragePermission() async {
    if (!Platform.isAndroid) return;
    await requestStoragePermission();
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      _androidLifecycleChannel.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    if (state == AppLifecycleState.detached) {
      ref.read(presenceProvider.notifier).stop();
      final player = ref.read(playerProvider.notifier);
      player.saveSession().catchError((_) {});
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ref.read(playerProvider.notifier).saveSession().catchError((_) {});
    }
  }

  final List<Widget> _screens = const [
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
    FriendsScreen(),
  ];

  // ── Create bottom sheet ──────────────────────────────────────────────────
  void _showCreateSheet() {
    final isGuest = ref.read(guestSessionProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF282828),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _CreateBottomSheet(
        showParty: !isGuest,
        onCreatePlaylist: () {
          Navigator.pop(context);
          // Switch to Library tab first, then show dialog
          setState(() {
            _currentIndex = 2;
            _visited.add(2);
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showCreatePlaylistDialog(context);
          });
        },
        onCreateParty: () {
          Navigator.pop(context);
          _showCreatePartySheet();
        },
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    var visibility = 'private';
    var collaborative = false;
    final isGuest = ref.read(guestSessionProvider);
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title:
              const Text('New Playlist', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Playlist name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: visibility,
                decoration: const InputDecoration(labelText: 'Privacy'),
                dropdownColor: const Color(0xFF282828),
                style: const TextStyle(color: Colors.white),
                items: ['private', 'friends', 'public']
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v[0].toUpperCase() + v.substring(1)),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => visibility = v ?? 'private'),
              ),
              if (!isGuest)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: collaborative,
                  title: const Text('Collaborative',
                      style: TextStyle(color: Colors.white)),
                  onChanged: (value) =>
                      setState(() => collaborative = value ?? false),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFFB3B3B3))),
            ),
            TextButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                try {
                  await ref.read(libraryProvider.notifier).createPlaylist(
                        name,
                        visibility: visibility,
                        collaborative: collaborative,
                      );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (error) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(
                          content: Text('Could not create playlist: $error')),
                    );
                  }
                }
              },
              child: const Text('Create',
                  style: TextStyle(color: Color(0xFF1DB954))),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreatePartySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF282828),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF555555),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Create a Party',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Listen together with friends in real time',
                style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30)),
                  ),
                  icon: const Icon(Icons.people),
                  label: const Text('Start Party',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  onPressed: () async {
                    Navigator.pop(context);
                    try {
                      await ref.read(listenPartyProvider.notifier).create(
                            openToFriends: true,
                          );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Party started! Share the code with friends.'),
                            backgroundColor: Color(0xFF1DB954),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Failed to create party: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerState>(playerProvider, (_, next) {
      ref.read(presenceProvider.notifier).updateFromPlayer(next);
    });
    final hasSong = ref.watch(
      playerProvider.select((playerState) => playerState.currentSong != null),
    );
    final isGuest = ref.watch(guestSessionProvider);
    final screens = isGuest ? _screens.take(3).toList() : _screens;

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: [
              for (var i = 0; i < screens.length; i++)
                _visited.contains(i) ? screens[i] : const SizedBox.shrink(),
            ],
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: RemotePlaybackBanner(),
            ),
          ),
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: OfflineIndicator(),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mini-player sits above the nav bar when a song is playing
          if (hasSong) const MiniPlayer(),
          _SpotifyBottomNav(
            currentIndex: _currentIndex,
            guestMode: isGuest,
            onTap: (i) {
              if (i == (isGuest ? 3 : 4)) {
                // Create — open bottom sheet
                _showCreateSheet();
              } else {
                setState(() {
                  _currentIndex = i;
                  _visited.add(i);
                });
              }
            },
          ),
        ],
      ),
    );
  }
}

// ─── Spotify-style bottom nav ─────────────────────────────────────────────────

class _SpotifyBottomNav extends StatelessWidget {
  final int currentIndex;
  final bool guestMode;
  final void Function(int) onTap;

  const _SpotifyBottomNav({
    required this.currentIndex,
    required this.guestMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_NavItem>[
      _NavItem(
          icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home'),
      _NavItem(
          icon: Icons.search_outlined,
          activeIcon: Icons.search,
          label: 'Search'),
      _NavItem(
          icon: Icons.library_music_outlined,
          activeIcon: Icons.library_music,
          label: 'Your Library'),
      if (!guestMode)
        _NavItem(
            icon: Icons.people_outline,
            activeIcon: Icons.people,
            label: 'Friends'),
      _NavItem(
          icon: Icons.add,
          activeIcon: Icons.add,
          label: 'Create',
          isCreate: true),
    ];

    return Container(
      color: const Color(0xFF0D0D0D),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final isSelected = i == currentIndex && !item.isCreate;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onTap(i),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSelected ? item.activeIcon : item.icon,
                        color: item.isCreate
                            ? Colors.white
                            : isSelected
                                ? Colors.white
                                : const Color(0xFFB3B3B3),
                        size: item.isCreate ? 26 : 24,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.label,
                        style: TextStyle(
                          color: item.isCreate
                              ? Colors.white
                              : isSelected
                                  ? Colors.white
                                  : const Color(0xFFB3B3B3),
                          fontSize: 10,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isCreate;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.isCreate = false,
  });
}

// ─── Create bottom sheet ──────────────────────────────────────────────────────

class _CreateBottomSheet extends StatelessWidget {
  final VoidCallback onCreatePlaylist;
  final VoidCallback onCreateParty;
  final bool showParty;

  const _CreateBottomSheet({
    required this.onCreatePlaylist,
    required this.onCreateParty,
    required this.showParty,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF555555),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Playlist option
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              leading: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: Color(0xFF3A3A3A),
                  shape: BoxShape.circle,
                ),
                child:
                    const Icon(Icons.music_note, color: Colors.white, size: 26),
              ),
              title: const Text(
                'Playlist',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
              subtitle: const Text(
                'Create a playlist with songs or episodes',
                style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
              ),
              onTap: onCreatePlaylist,
            ),

            // Party option
            if (showParty)
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                leading: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: Color(0xFF3A3A3A),
                    shape: BoxShape.circle,
                  ),
                  child:
                      const Icon(Icons.people, color: Colors.white, size: 26),
                ),
                title: const Text(
                  'Party',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
                subtitle: const Text(
                  'Listen together with friends in real time',
                  style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
                ),
                onTap: onCreateParty,
              ),
          ],
        ),
      ),
    );
  }
}
