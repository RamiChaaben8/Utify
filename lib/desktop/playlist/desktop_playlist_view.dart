// ============================================================
// desktop/playlist/desktop_playlist_view.dart
//
// Full-center playlist view for the desktop shell.
// Shows playlist header (art, name, song count), a Play All
// button, and a scrollable list of songs. Each song can be
// played individually; right-click or ··· opens the context menu.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/firestore_service.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/song_context_menu.dart';
import '../theme/desktop_theme.dart';
import '../theme/ui_sizes.dart';
import '../widgets/invite_collaborator_dialog.dart';
import '../widgets/song_leading_indicator.dart';

class DesktopPlaylistView extends ConsumerStatefulWidget {
  final Playlist playlist;

  const DesktopPlaylistView({super.key, required this.playlist});

  @override
  ConsumerState<DesktopPlaylistView> createState() =>
      _DesktopPlaylistViewState();
}

class _DesktopPlaylistViewState extends ConsumerState<DesktopPlaylistView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    // Always read the live version from the provider so edits reflect instantly
    final library = ref.watch(libraryProvider);
    final live = library.playlists.firstWhere(
      (p) {
        // Prefer Firestore ID match, fall back to Hive key
        final fsId = widget.playlist.firestoreId;
        if (fsId != null && p.firestoreId == fsId) return true;
        if (widget.playlist.sharedId != null &&
            p.sharedId == widget.playlist.sharedId) return true;
        final hiveKey = widget.playlist.key;
        if (hiveKey != null && p.key == hiveKey) return true;
        return false;
      },
      orElse: () => widget.playlist,
    );
    final songs = live.songs
        .where((song) =>
            _query.trim().isEmpty ||
            song.title.toLowerCase().contains(_query.toLowerCase()) ||
            song.channelName.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: context.appTheme.panelSurfaceColor,
        borderRadius: BorderRadius.all(
          Radius.circular(context.appTheme.layout.panelRadius),
        ),
      ),
      child: CustomScrollView(
        slivers: [
          // ── Header ────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: _PlaylistHeader(
              playlist: live,
              songs: songs,
              onSearchChanged: (value) => setState(() => _query = value),
            ),
          ),

          // ── Song count row ────────────────────────────────────────────
          if (songs.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Row(
                  children: [
                    Text(
                      '${songs.length} song${songs.length == 1 ? '' : 's'}',
                      style: TextStyle(
                          color: context.appTheme.subtext, fontSize: 13),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 56,
                      child: Text(
                        'Duration',
                        style: TextStyle(
                            color: context.appTheme.subtext, fontSize: 12),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    SizedBox(width: 40),
                  ],
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: Divider(
                color: context.appTheme.dividerColor,
                height: 1,
                thickness: 0.5,
                indent: 24,
                endIndent: 24),
          ),

          // ── Song list ─────────────────────────────────────────────────
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.queue_music,
                        color: context.appTheme.subtext, size: 56),
                    SizedBox(height: 12),
                    Text(
                      'No songs yet.\nAdd songs using the ··· menu.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: context.appTheme.subtext, fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          else if (_query.trim().isEmpty)
            // Drag-to-reorder is only offered on the unfiltered list: while a
            // search is active the row indices no longer line up with the
            // playlist's real order, so a drop would move the wrong song.
            SliverReorderableList(
              itemCount: songs.length,
              onReorder: (oldIndex, newIndex) => ref
                  .read(libraryProvider.notifier)
                  .reorderPlaylistSongs(live, oldIndex, newIndex),
              proxyDecorator: (child, index, animation) => Material(
                color: context.appTheme.card,
                elevation: 6,
                borderRadius: BorderRadius.circular(6),
                child: child,
              ),
              itemBuilder: (ctx, i) => _SongRow(
                key: ValueKey(songs[i].id),
                song: songs[i],
                index: i,
                playlist: live,
                allSongs: songs,
                reorderable: true,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _SongRow(
                  song: songs[i],
                  index: i,
                  playlist: live,
                  allSongs: songs,
                ),
                childCount: songs.length,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────

class _PlaylistHeader extends ConsumerWidget {
  final Playlist playlist;
  final List<Song> songs;
  final ValueChanged<String> onSearchChanged;

  const _PlaylistHeader({
    required this.playlist,
    required this.songs,
    required this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = songs.isNotEmpty ? songs.first.thumbnailUrl : '';
    final accountName =
        ref.watch(authServiceProvider).currentUser?.displayName?.trim();
    final creatorName = playlist.ownerName?.trim().isNotEmpty == true
        ? playlist.ownerName!.trim()
        : accountName?.isNotEmpty == true
            ? accountName!
            : (ref.watch(authServiceProvider).currentUser?.email ?? 'You');
    final totalDuration = songs.fold<Duration>(
        Duration.zero, (total, song) => total + song.duration);

    return Container(
      decoration: context.appTheme.isVerdantNightDesktop
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.appTheme.headerGradientColor,
                  context.appTheme.main.withValues(alpha: 0),
                ],
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(38, 28, 38, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Art
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumb.isEmpty
                      ? Container(
                          width: 232,
                          height: 232,
                          color: context.appTheme.misc.withValues(alpha: 0.35),
                          child: Icon(Icons.queue_music,
                              color: context.appTheme.subtext
                                  .withValues(alpha: 0.38),
                              size: 72),
                        )
                      : CachedNetworkImage(
                          imageUrl: thumb,
                          width: 232,
                          height: 232,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                              width: 232,
                              height: 232,
                              color: context.appTheme.misc
                                  .withValues(alpha: 0.35)),
                          errorWidget: (_, __, ___) => Container(
                            width: 232,
                            height: 232,
                            color:
                                context.appTheme.misc.withValues(alpha: 0.35),
                            child: Icon(Icons.queue_music,
                                color: context.appTheme.subtext
                                    .withValues(alpha: 0.38),
                                size: 72),
                          ),
                        ),
                ),

                const SizedBox(width: 28),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: context.appTheme.isVerdantNightDesktop
                                  ? context.appTheme.text
                                  : context.appTheme.button,
                              width: context.appTheme.isVerdantNightDesktop
                                  ? 1
                                  : 1.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${playlist.visibility[0].toUpperCase()}${playlist.visibility.substring(1)} Playlist',
                          style: TextStyle(
                            color: context.appTheme.isVerdantNightDesktop
                                ? context.appTheme.text
                                : context.appTheme.button,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appTheme.isVerdantNightDesktop
                              ? context.appTheme.text
                              : context.appTheme.button,
                          fontSize: PlaylistSizes.headerTitle,
                          height: 0.98,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Invite to playlist',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            onPressed: () => _invite(context, ref),
                            icon: Icon(Icons.add_circle_outline,
                                size: 18, color: context.appTheme.subtext),
                          ),
                          const SizedBox(width: 4),
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: context.appTheme.card,
                            child: Icon(Icons.person,
                                size: 15, color: context.appTheme.subtext),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            creatorName,
                            style: TextStyle(
                                color: context.appTheme.subtext,
                                fontSize: PlaylistSizes.headerSubtitle),
                          ),
                          Text(
                            '  •  ${songs.length} songs  •  ${_formatDuration(totalDuration)}',
                            style: TextStyle(
                                color: context.appTheme.subtext,
                                fontSize: PlaylistSizes.headerSubtitle),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.appTheme.button,
                    foregroundColor: context.appTheme.isVerdantNightDesktop
                        ? context.appTheme.playIconColor
                        : context.appTheme.text,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: const StadiumBorder(),
                    elevation: 0,
                  ),
                  onPressed: songs.isEmpty
                      ? null
                      : () => ref
                          .read(playerProvider.notifier)
                          .playSong(songs.first, queue: songs),
                  icon: const Icon(Icons.play_arrow, size: 22),
                  label: const Text('Play All',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        context.appTheme.iconColor(context.appTheme.text),
                    side: BorderSide(color: context.appTheme.dividerColor),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: songs.isEmpty
                      ? null
                      : () {
                          ref.read(playerProvider.notifier).toggleShuffle();
                          ref
                              .read(playerProvider.notifier)
                              .playSong(songs.first, queue: songs);
                        },
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Shuffle'),
                ),
                const SizedBox(width: 8),
                _DownloadButton(songs: songs),
                IconButton(
                  tooltip: 'Invite collaborator',
                  onPressed: () => _invite(context, ref),
                  icon: const Icon(Icons.person_add_alt_1),
                ),
                IconButton(
                  tooltip: 'Name & details',
                  onPressed: () => _rename(context, ref),
                  icon: const Icon(Icons.more_horiz),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 360,
                  child: TextField(
                    onChanged: onSearchChanged,
                    style: TextStyle(color: context.appTheme.text),
                    decoration: InputDecoration(
                      hintText: 'Search in this playlist',
                      hintStyle: TextStyle(color: context.appTheme.subtext),
                      prefixIcon:
                          Icon(Icons.search, color: context.appTheme.subtext),
                      filled: true,
                      fillColor: context.appTheme.card,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}min';
    }
    return '${duration.inMinutes}min';
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Name & details',
            style: TextStyle(color: context.appTheme.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: context.appTheme.text),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: context.appTheme.subtext),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: TextStyle(color: context.appTheme.subtext))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text('Save',
                  style: TextStyle(color: context.appTheme.text))),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await ref
          .read(libraryProvider.notifier)
          .renamePlaylistObj(playlist, name);
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final selected = await showCollaboratorInviteDialog(context, ref, playlist);
    if (selected != null) {
      try {
        await ref
            .read(libraryProvider.notifier)
            .inviteCollaborator(playlist, selected);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Playlist invitation sent.')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error.toString())),
          );
        }
      }
    }
  }
}

// ─── Download button (playlist-level) ────────────────────────────────────────

class _DownloadButton extends ConsumerWidget {
  final List<Song> songs;
  const _DownloadButton({required this.songs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ds = ref.watch(downloadProvider);
    if (songs.isEmpty) {
      return IconButton(
        tooltip: 'Download playlist',
        onPressed: null,
        icon: const Icon(Icons.download_outlined),
      );
    }

    final onlineSongs = songs.where((s) => !s.isLocal).toList();
    final totalOnline = onlineSongs.length;
    final downloadedCount =
        onlineSongs.where((s) => ds.isDownloaded(s.id)).length;
    final downloadingCount =
        onlineSongs.where((s) => ds.isDownloading(s.id)).length;
    final allDone = totalOnline > 0 && downloadedCount == totalOnline;
    final anyDownloading = downloadingCount > 0;

    // Aggregate progress across all actively downloading songs
    double avgProgress = 0;
    if (anyDownloading) {
      final total = onlineSongs
          .where((s) => ds.isDownloading(s.id))
          .fold<double>(0, (sum, s) => sum + ds.progressFor(s.id));
      avgProgress = total / downloadingCount;
    }

    final tooltipMsg = allDone
        ? 'Playlist downloaded ($downloadedCount/$totalOnline)'
        : anyDownloading
            ? 'Downloading… ${downloadedCount + downloadingCount}/$totalOnline'
            : downloadedCount > 0
                ? 'Download remaining (${totalOnline - downloadedCount} songs)'
                : 'Download playlist ($totalOnline songs)';

    return Tooltip(
      message: tooltipMsg,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (anyDownloading)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      value: avgProgress > 0 ? avgProgress : null,
                      strokeWidth: 2.5,
                      color: context.appTheme.isVerdantNightDesktop
                          ? context.appTheme.subtext
                          : context.appTheme.button,
                      backgroundColor:
                          context.appTheme.subtext.withValues(alpha: 0.2),
                    ),
                  ),
                IconButton(
                  padding: EdgeInsets.zero,
                  onPressed: allDone || anyDownloading
                      ? null
                      : () {
                          for (final song in onlineSongs) {
                            if (!ds.isDownloaded(song.id)) {
                              ref
                                  .read(downloadProvider.notifier)
                                  .downloadSong(song);
                            }
                          }
                        },
                  icon: Icon(
                    allDone
                        ? Icons.download_done
                        : anyDownloading
                            ? Icons.downloading
                            : Icons.download_outlined,
                    color: allDone
                        ? context.appTheme.iconColor(context.appTheme.button)
                        : anyDownloading
                            ? context.appTheme.subtext
                            : context.appTheme.subtext,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
          if (totalOnline > 0)
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 6),
              child: Text(
                '$downloadedCount/$totalOnline',
                style: TextStyle(
                  color: allDone
                      ? context.appTheme.iconColor(context.appTheme.button)
                      : context.appTheme.subtext,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Song row ─────────────────────────────────────────────────────────────────

class _SongRow extends ConsumerStatefulWidget {
  final Song song;
  final int index;
  final Playlist playlist;
  final List<Song> allSongs;

  /// False on the filtered (searching) list, which is not reorderable.
  final bool reorderable;

  const _SongRow({
    super.key,
    required this.song,
    required this.index,
    required this.playlist,
    required this.allSongs,
    this.reorderable = false,
  });

  @override
  ConsumerState<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<_SongRow> {
  bool _hovered = false;

  String _fmt(Duration d) {
    if (d == Duration.zero) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(playerProvider);
    final isCurrent = ps.currentSong?.id == widget.song.id;
    final notifier = ref.read(playerProvider.notifier);

    // Play this song, or toggle the current one, without leaving the row.
    void toggleFromIndicator() {
      if (!isCurrent) {
        notifier.playSong(widget.song, queue: widget.allSongs);
      } else if (ps.isPlaying) {
        notifier.pause();
      } else {
        notifier.play();
      }
    }

    return SongContextMenu(
      song: widget.song,
      currentPlaylist: widget.playlist,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: _hovered
              ? context.appTheme.highlight
              : isCurrent
                  ? context.appTheme.selectedRow
                  : context.appTheme.main.withValues(alpha: 0),
          child: InkWell(
            onTap: () => notifier.playSong(widget.song, queue: widget.allSongs),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              child: Row(
                children: [
                  // Index → play/pause → animated equalizer, fixed slot.
                  SongLeadingIndicator(
                    number: widget.index + 1,
                    isCurrent: isCurrent,
                    isPlaying: ps.isPlaying,
                    hovered: _hovered,
                    accent: context.appTheme.nowPlayingAccent,
                    numberColor: context.appTheme.subtext,
                    onTap: toggleFromIndicator,
                  ),
                  SizedBox(width: 16),

                  // Thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: widget.song.thumbnailUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: widget.song.thumbnailUrl,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                                width: 44,
                                height: 44,
                                color: context.appTheme.card),
                            errorWidget: (_, __, ___) => Container(
                              width: 44,
                              height: 44,
                              color: context.appTheme.card,
                              child: Icon(Icons.music_note,
                                  color: context.appTheme.subtext
                                      .withValues(alpha: 0.54),
                                  size: 18),
                            ),
                          )
                        : Container(
                            width: 44,
                            height: 44,
                            color: context.appTheme.card,
                            child: Icon(Icons.music_note,
                                color: context.appTheme.subtext
                                    .withValues(alpha: 0.54),
                                size: 18),
                          ),
                  ),
                  SizedBox(width: 14),

                  // Title + artist
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isCurrent
                                ? context.appTheme.nowPlayingAccent
                                : context.appTheme.text,
                            fontSize: 14,
                            fontWeight:
                                isCurrent ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          widget.song.channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: context.appTheme.subtext, fontSize: 12),
                        ),
                      ],
                    ),
                  ),

                  // Duration
                  SizedBox(
                    width: 56,
                    child: Text(
                      _fmt(widget.song.duration),
                      style: TextStyle(
                          color: context.appTheme.subtext, fontSize: 13),
                      textAlign: TextAlign.right,
                    ),
                  ),

                  // Download indicator (progress circle or tick)
                  if (!widget.song.isLocal)
                    _SongDownloadIndicator(song: widget.song),

                  // ··· button (visible on hover)
                  AnimatedOpacity(
                    opacity: _hovered || isCurrent ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: SongMenuButton(
                      song: widget.song,
                      currentPlaylist: widget.playlist,
                    ),
                  ),

                  // Drag handle (visible on hover) — reorders songs inside the
                  // playlist. Fixed slot so the row never shifts.
                  SizedBox(
                    width: widget.reorderable ? 28 : 0,
                    height: 28,
                    child: AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: ReorderableDragStartListener(
                        index: widget.index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Icon(
                            Icons.drag_handle,
                            color: context.appTheme.subtext,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Per-song download indicator ─────────────────────────────────────────────

class _SongDownloadIndicator extends ConsumerWidget {
  final Song song;
  const _SongDownloadIndicator({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ds = ref.watch(downloadProvider);
    final downloaded = ds.isDownloaded(song.id);
    final downloading = ds.isDownloading(song.id);
    final progress = ds.progressFor(song.id);

    if (!downloaded && !downloading) return const SizedBox(width: 32);

    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (downloading)
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: progress > 0 ? progress : null,
                strokeWidth: 2,
                color: context.appTheme.isVerdantNightDesktop
                    ? context.appTheme.subtext
                    : context.appTheme.button,
                backgroundColor:
                    context.appTheme.subtext.withValues(alpha: 0.2),
              ),
            )
          else
            Icon(
              Icons.check_circle,
              size: 18,
              color: context.appTheme.iconColor(context.appTheme.button),
            ),
        ],
      ),
    );
  }
}
