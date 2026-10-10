// ============================================================
// widgets/mini_player.dart
//
// Spotify-style mini-player bar shown above the bottom nav bar.
//
// Layout:
//   ┌──────────────────────────────────────────────────────────┐
//   │  ▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  (thin green progress bar)  │
//   │  [thumb]  Title • Artist        |◀  ▶  ▶|  cast         │
//   │           Next: Song name                                │
//   └──────────────────────────────────────────────────────────┘
//
// Tapping the body opens NowPlayingScreen.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/artwork_cache_manager.dart';

import '../providers/player_provider.dart';
import '../screens/now_playing_screen.dart';
import '../desktop/theme/desktop_theme.dart';
import 'device_picker.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));

    if (song == null) return const SizedBox.shrink();

    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final idx = ref.watch(playerProvider.select((s) => s.currentIndex));
    final isLoading = ref.watch(playerProvider.select((s) => s.isLoading));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final nextSong =
        queue.length > 1 ? queue[(idx + 1) % queue.length] : null;

    final theme = context.appTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openPlayer(context),
      child: Container(
        // No extra margin — sits flush above the nav bar like Spotify
        decoration: BoxDecoration(
          color: theme.player,
          border: Border(
            top: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Thin green progress bar ──────────────────────────────
            const _MiniProgress(),

            // ── Content row ──────────────────────────────────────────
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  const SizedBox(width: 8),

                  // ── Thumbnail ──────────────────────────────────────
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CachedNetworkImage(
                      imageUrl: song.thumbnailUrl,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      memCacheWidth: 192,
                      memCacheHeight: 192,
                      cacheManager: ArtworkCacheManager.instance,
                      placeholder: (_, __) => Container(
                        width: 48,
                        height: 48,
                        color: theme.card,
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 48,
                        height: 48,
                        color: theme.card,
                        child: Icon(Icons.music_note,
                            color: theme.subtext.withValues(alpha: 0.3),
                            size: 22),
                      ),
                    ),
                  ),

                  const SizedBox(width: 10),

                  // ── Title, artist & next ───────────────────────────
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title • Channel
                        RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: song.title,
                                style: TextStyle(
                                  color: theme.text,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              TextSpan(
                                text: ' • ${song.channelName}',
                                style: TextStyle(
                                  color: theme.subtext,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (nextSong != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                'Next: ',
                                style: TextStyle(
                                  color: theme.nowPlayingAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  nextSong.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: theme.subtext,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  // ── Controls ───────────────────────────────────────
                  if (isLoading)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.button,
                        ),
                      ),
                    )
                  else ...[
                    // Skip previous
                    _MiniButton(
                      icon: Icons.skip_previous,
                      onTap: () => ref
                          .read(playerProvider.notifier)
                          .skipToPrevious(),
                    ),
                    // Play / Pause
                    _MiniButton(
                      icon: isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                      size: 28,
                      onTap: () => ref
                          .read(playerProvider.notifier)
                          .togglePlayPause(),
                    ),
                    // Skip next
                    _MiniButton(
                      icon: Icons.skip_next,
                      onTap: () =>
                          ref.read(playerProvider.notifier).skipToNext(),
                    ),
                    // Cast / device picker
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: DevicePickerButton(size: 18),
                    ),
                  ],

                  const SizedBox(width: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NowPlayingScreen(),
        transitionsBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }
}

// ─── Compact icon button ────────────────────────────────────────────────────

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;

  const _MiniButton({
    required this.icon,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 36,
        height: 48,
        child: Icon(icon, color: context.appTheme.iconDefault, size: size),
      ),
    );
  }
}

class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(playerProvider.select((s) =>
        s.duration.inMilliseconds > 0
            ? (s.position.inMilliseconds / s.duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0));
    final theme = context.appTheme;

    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: theme.shadow,
        valueColor: AlwaysStoppedAnimation<Color>(theme.button),
      ),
    );
  }
}

