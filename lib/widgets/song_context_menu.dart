// ============================================================
// widgets/song_context_menu.dart
//
// Shared right-click / ··· context menu for any Song.
// Menu items:
//   • Add to playlist
//   • Remove from this playlist (only when currentPlaylist != null)
//   • Save to your Liked Songs / Remove from Liked Songs (toggle)
//   • Add to queue
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../models/playlist.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../providers/panel_provider.dart';
import '../screens/queue_screen.dart';
import '../desktop/theme/desktop_theme.dart';

// ─── Public API ───────────────────────────────────────────────────────────────

/// Wraps [child] with a right-click handler that opens the context menu.
class SongContextMenu extends ConsumerWidget {
  final Song song;
  final Playlist? currentPlaylist;
  final Widget child;

  const SongContextMenu({
    super.key,
    required this.song,
    required this.child,
    this.currentPlaylist,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => showSongContextMenu(
        context: context,
        ref: ref,
        song: song,
        position: d.globalPosition,
        currentPlaylist: currentPlaylist,
      ),
      child: child,
    );
  }
}

/// Standalone function — call this from a button's onPressed to show the menu
/// anchored at [position] (global coordinates).
Future<void> showSongContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Song song,
  required Offset position,
  Playlist? currentPlaylist,
}) async {
  final library = ref.read(libraryProvider);
  final isLiked = library.isLiked(song.id);
  final downloadState = ref.read(downloadProvider);
  final isDownloaded = downloadState.isDownloaded(song.id);
  final isDownloading = downloadState.isDownloading(song.id);
  final theme = AppThemeScope.maybeOf(context);

  final result = await showMenu<_Action>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx + 1,
      position.dy + 1,
    ),
    color: theme?.card ?? const Color(0xFF282828),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    items: [
      PopupMenuItem(
        value: _Action.addToPlaylist,
        child: _row(Icons.add, 'Add to playlist', theme: theme),
      ),
      if (currentPlaylist != null)
        PopupMenuItem(
          value: _Action.removeFromPlaylist,
          child: _row(Icons.remove_circle_outline, 'Remove from this playlist',
              theme: theme),
        ),
      if (currentPlaylist == null)
        PopupMenuItem(
          value: _Action.toggleLike,
          child: _row(
            isLiked ? Icons.favorite : Icons.favorite_border,
            isLiked ? 'Remove from Liked Songs' : 'Save to your Liked Songs',
            color: isLiked ? theme?.nowPlayingAccent ?? const Color(0xFF1DB954) : null,
            theme: theme,
          ),
        ),
      PopupMenuItem(
        value: _Action.addToQueue,
        child: _row(Icons.queue_music, 'Add to queue', theme: theme),
      ),
      // Download option — only for online songs not yet downloaded or downloading
      if (!song.isLocal && !isDownloaded && !isDownloading)
        PopupMenuItem(
          value: _Action.downloadSong,
          child: _row(Icons.download_outlined, 'Download',
              color: theme?.nowPlayingAccent ?? const Color(0xFF1DB954),
              theme: theme),
        ),
      if (isDownloading)
        PopupMenuItem(
          value: _Action.cancelDownload,
          child: _row(Icons.cancel_outlined, 'Cancel download',
              color: theme?.warning ?? Colors.orange, theme: theme),
        ),
      if (isDownloaded)
        PopupMenuItem(
          value: _Action.deleteDownload,
          child: _row(Icons.delete_outline, 'Delete downloaded file',
              color: theme?.notificationError ?? Colors.redAccent,
              theme: theme),
        ),
      if (currentPlaylist != null)
        PopupMenuItem(
          value: _Action.goToQueue,
          child: _row(Icons.queue_play_next, 'Go to queue', theme: theme),
        ),
    ],
  );

  if (result == null || !context.mounted) return;

  switch (result) {
    case _Action.addToPlaylist:
      await _addToPlaylist(context, ref, song);
    case _Action.removeFromPlaylist:
      if (currentPlaylist != null) {
        await ref
            .read(libraryProvider.notifier)
            .removeSongFromPlaylistObj(currentPlaylist, song.id);
        if (context.mounted) {
          _snack(context, 'Removed from ${currentPlaylist.name}');
        }
      }
    case _Action.toggleLike:
      await ref.read(libraryProvider.notifier).toggleLike(song);
      if (context.mounted) {
        final liked = ref.read(libraryProvider).isLiked(song.id);
        _snack(context,
            liked ? 'Saved to Liked Songs' : 'Removed from Liked Songs');
      }
    case _Action.addToQueue:
      ref.read(playerProvider.notifier).addToQueue(song);
      if (context.mounted) _snack(context, 'Added to queue');
    case _Action.downloadSong:
      ref.read(downloadProvider.notifier).downloadSong(song);
      if (context.mounted) _snack(context, 'Downloading "${song.title}"…');
    case _Action.cancelDownload:
      ref.read(downloadProvider.notifier).cancelDownload(song.id);
      if (context.mounted) _snack(context, 'Cancelled download');
    case _Action.goToQueue:
      if (isDesktopLayout) {
        // On desktop the queue is a side panel, not a screen. Pushing the
        // mobile QueueScreen stacked a hardcoded mobile Scaffold (with its own
        // #0A0A0A AppBar) on top of the desktop shell.
        ref.read(panelModeProvider.notifier).state = PanelMode.queue;
      } else if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const QueueScreen()),
        );
      }
    case _Action.deleteDownload:
      await ref.read(downloadProvider.notifier).deleteSong(song.id);
      if (context.mounted) _snack(context, 'Downloaded file deleted');
  }
}

// ─── Three-dot icon button ────────────────────────────────────────────────────

/// An IconButton(Icons.more_horiz) that opens the context menu when tapped.
/// Drop this anywhere as a trailing widget or overlay.
class SongMenuButton extends ConsumerWidget {
  final Song song;
  final Playlist? currentPlaylist;

  /// Icon colour. Defaults to [Color(0xFFB3B3B3)].
  final Color? color;
  final double size;

  const SongMenuButton({
    super.key,
    required this.song,
    this.currentPlaylist,
    this.color,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = AppThemeScope.maybeOf(context);
    return IconButton(
      icon: Icon(Icons.more_horiz,
          color: color ?? theme?.subtext ?? const Color(0xFFB3B3B3),
          size: size),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      splashRadius: 16,
      tooltip: 'More options',
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final pos = box.localToGlobal(Offset.zero);
        final sz = box.size;
        showSongContextMenu(
          context: context,
          ref: ref,
          song: song,
          position: Offset(pos.dx + sz.width / 2, pos.dy + sz.height),
          currentPlaylist: currentPlaylist,
        );
      },
    );
  }
}

// ─── Internals ────────────────────────────────────────────────────────────────

enum _Action {
  addToPlaylist,
  removeFromPlaylist,
  toggleLike,
  addToQueue,
  goToQueue,
  downloadSong,
  cancelDownload,
  deleteDownload,
}

Widget _row(IconData icon, String label, {Color? color, AppThemeData? theme}) {
  final c = color ?? theme?.text ?? Colors.white;
  return Row(
    children: [
      Icon(icon, color: c, size: 18),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: c, fontSize: 14)),
    ],
  );
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor:
        AppThemeScope.maybeOf(context)?.button ?? const Color(0xFF1DB954),
    duration: const Duration(seconds: 2),
  ));
}

Future<void> _addToPlaylist(
    BuildContext context, WidgetRef ref, Song song) async {
  final library = ref.read(libraryProvider);
  if (library.playlists.isEmpty) {
    _snack(context, 'No playlists yet — create one first');
    return;
  }
  final theme = AppThemeScope.maybeOf(context);

  final playlist = await showDialog<Playlist>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor:
          AppThemeScope.maybeOf(context)?.card ?? const Color(0xFF282828),
      title: Text('Add to playlist',
          style: TextStyle(color: theme?.text ?? Colors.white, fontSize: 16)),
      content: SizedBox(
        width: 300,
        child: ListView(
          shrinkWrap: true,
          children: library.playlists.map((p) {
            return ListTile(
              dense: true,
              title: Text(p.name,
                  style: TextStyle(
                      color: theme?.text ?? Colors.white, fontSize: 14)),
              subtitle: Text('${p.songs.length} songs',
                  style: TextStyle(
                      color: theme?.subtext ?? const Color(0xFFB3B3B3),
                      fontSize: 12)),
              onTap: () => Navigator.pop(ctx, p),
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Cancel',
              style:
                  TextStyle(color: theme?.subtext ?? const Color(0xFFB3B3B3))),
        ),
      ],
    ),
  );

  if (playlist != null && context.mounted) {
    await ref
        .read(libraryProvider.notifier)
        .addSongToPlaylistObj(playlist, song);
    if (context.mounted) {
      _snack(context, 'Added to ${playlist.name}');
    }
  }
}
