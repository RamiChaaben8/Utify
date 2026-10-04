// ============================================================
// screens/playlist_screen.dart
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/song.dart';
import '../models/playlist.dart';
import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/guest_session_provider.dart';
import '../services/firestore_service.dart';
import '../screens/library_screen.dart';
import '../screens/now_playing_screen.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import '../desktop/widgets/invite_collaborator_dialog.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String title;
  final List<Song> songs;

  /// Pass the full Playlist object for custom playlists (enables remove-song button).
  final Playlist? playlist;

  /// Legacy: accepted for backward-compat — prefer [playlist] instead.
  final int? playlistKey;
  final IconData? icon;

  /// If set, locks the filter to this value (e.g. Local Music entry).
  final SongFilter? forcedFilter;

  const PlaylistScreen({
    super.key,
    required this.title,
    required this.songs,
    this.playlist,
    this.playlistKey,
    this.icon,
    this.forcedFilter,
  });

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  late SongFilter _filter;
  late List<Song> _songs;
  bool _editingOrder = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.forcedFilter ?? SongFilter.all;
    _songs = List<Song>.from(widget.songs);
  }

  List<Song> get _filtered => applyFilter(_songs, _filter);

  Playlist? _currentPlaylist() {
    final target = widget.playlist;
    if (target == null) return null;
    final playlists = ref.read(libraryProvider).playlists;
    for (final playlist in playlists) {
      if (target.sharedId != null && playlist.sharedId == target.sharedId) {
        return playlist;
      }
      if (target.firestoreId != null &&
          playlist.firestoreId == target.firestoreId) {
        return playlist;
      }
      if (target.key != null && playlist.key == target.key) {
        return playlist;
      }
    }
    return target;
  }

  void _playSong(Song song, List<Song> queue) {
    final currentId = ref.read(playerProvider).currentSong?.id;
    if (currentId == song.id) {
      // Song is already playing — just open the player without restarting
      _openPlayer();
      return;
    }

    ref
        .read(playerProvider.notifier)
        .playSong(song, queue: queue, sourcePlaylist: widget.playlist);
    _openPlayer();
  }

  void _playPlaylist({required bool shuffle}) {
    if (_songs.isEmpty) return;
    final player = ref.read(playerProvider.notifier);
    final currentShuffle = ref.read(playerProvider).shuffle;
    if (currentShuffle != shuffle) player.toggleShuffle();
    player.playSong(
      _songs.first,
      queue: _songs,
      sourcePlaylist: widget.playlist,
    );
    _openPlayer();
  }

  void _downloadPlaylist() {
    final download = ref.read(downloadProvider.notifier);
    final ds = ref.read(downloadProvider);
    final currentPlaylist = _currentPlaylist();
    final songs = currentPlaylist?.songs ?? _songs;
    for (final song in songs.where((song) => !song.isLocal)) {
      if (!ds.isDownloaded(song.id)) {
        download.downloadSong(song);
      }
    }
  }

  void _openPlayer() {
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

  Widget _buildPlaylistActions() {
    final playlist = _currentPlaylist();
    final canEdit = playlist == null ||
        playlist.sharedId == null ||
        playlist.ownerUid ==
            ref.read(authServiceProvider).currentUser?.uid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          if (canEdit)
            _ActionChip(
              icon: _editingOrder ? Icons.check : Icons.sort,
              label: _editingOrder ? 'Done' : 'Edit order',
              onTap: () => setState(() => _editingOrder = !_editingOrder),
            ),
          const SizedBox(width: 8),
          if (canEdit) ...[
            const SizedBox(width: 8),
            _ActionChip(
              icon: Icons.edit_outlined,
              label: 'Name & details',
              onTap: _showPlaylistDetails,
            ),
          ],
        ],
      ),
    );
  }

  void _showPlaylistDetails() {
    final playlist = _currentPlaylist();
    if (playlist == null) return;
    final isOwner = playlist.sharedId == null ||
        playlist.ownerUid == ref.read(authServiceProvider).currentUser?.uid;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF282828),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Edit name'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameDialog(playlist);
              },
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.lock_outline, color: Colors.white),
              title: const Text('Privacy'),
              subtitle: Text(playlist.visibility),
              onTap: () {
                Navigator.pop(sheetContext);
                _showVisibilityMenu(playlist);
              },
            ),
            if (isOwner && !ref.read(guestSessionProvider))
              ListTile(
              leading:
                  const Icon(Icons.group_add_outlined, color: Colors.white),
              title: Text(
                playlist.sharedId == null
                    ? 'Make collaborative'
                    : 'Invite collaborator',
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                if (playlist.sharedId == null) {
                  final sharedId = await ref
                      .read(libraryProvider.notifier)
                      .makePlaylistCollaborative(playlist);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Playlist is now collaborative.')),
                  );
                  if (sharedId != null) {
                    // Build an up-to-date playlist object with the fresh sharedId.
                    final updatedPlaylist = Playlist(
                      name: playlist.name,
                      songs: playlist.songs,
                      createdAt: playlist.createdAt,
                      description: playlist.description,
                      visibility: playlist.visibility,
                      pinned: playlist.pinned,
                      folderId: playlist.folderId,
                      sharedId: sharedId,
                      ownerUid: ref
                          .read(authServiceProvider)
                          .currentUser
                          ?.uid,
                    );
                    playlistFirestoreIds[updatedPlaylist] = sharedId;
                    if (mounted) {
                      final selected = await showCollaboratorInviteDialog(
                          context, ref, updatedPlaylist);
                      if (selected != null && mounted) {
                        try {
                          await ref
                              .read(libraryProvider.notifier)
                              .inviteCollaborator(updatedPlaylist, selected);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Playlist invitation sent.')),
                            );
                          }
                        } catch (error) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        }
                      }
                    }
                  }
                } else {
                  final selected = await showCollaboratorInviteDialog(
                      context, ref, playlist);
                  if (selected != null) {
                    await ref
                        .read(libraryProvider.notifier)
                        .inviteCollaborator(playlist, selected);
                  }
                }
              },
            ),
            if (isOwner)
              ListTile(
              leading: Icon(
                playlist.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: Colors.white,
              ),
              title: Text(playlist.pinned ? 'Unpin playlist' : 'Pin playlist'),
              onTap: () {
                Navigator.pop(sheetContext);
                ref.read(libraryProvider.notifier).organizePlaylist(
                      playlist,
                      pinned: !playlist.pinned,
                    );
              },
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.folder_outlined, color: Colors.white),
              title: const Text('Add to folder'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showFolderPicker(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add, color: Colors.white),
              title: const Text('Add to another playlist'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showCopyPlaylistDialog(playlist);
              },
            ),
            ListTile(
              leading: Icon(isOwner ? Icons.delete_outline : Icons.logout,
                  color: isOwner ? Colors.red : Colors.white),
              title: Text(isOwner ? 'Delete playlist' : 'Quit playlist',
                  style: TextStyle(color: isOwner ? Colors.red : Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                if (isOwner) {
                  _showDeleteDialog(playlist);
                } else {
                  _quitPlaylist(playlist);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quitPlaylist(Playlist playlist) async {
    await ref
        .read(libraryProvider.notifier)
        .quitCollaborativePlaylist(playlist);
    if (mounted) Navigator.pop(context);
  }

  void _showRenameDialog(Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Edit playlist name',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              ref
                  .read(libraryProvider.notifier)
                  .renamePlaylistObj(playlist, name);
              Navigator.pop(dialogContext);
            },
            child:
                const Text('Save', style: TextStyle(color: Color(0xFF1DB954))),
          ),
        ],
      ),
    );
  }

  void _showVisibilityMenu(Playlist playlist) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in ['private', 'friends', 'public'])
            RadioListTile<String>(
              value: value,
              groupValue: playlist.visibility,
              title: Text(value[0].toUpperCase() + value.substring(1)),
              onChanged: (next) {
                if (next == null) return;
                ref
                    .read(libraryProvider.notifier)
                    .setPlaylistVisibility(playlist, next);
                Navigator.pop(sheetContext);
              },
            ),
        ],
      ),
    );
  }

  void _showFolderPicker(Playlist playlist) {
    final folders = ref.read(libraryProvider).folders;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title:
                  Text('Choose folder', style: TextStyle(color: Colors.white)),
            ),
            ...folders.map((folder) => ListTile(
                  leading:
                      const Icon(Icons.folder_outlined, color: Colors.white70),
                  title:
                      Text(folder, style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    ref.read(libraryProvider.notifier).organizePlaylist(
                          playlist,
                          folderId: folder,
                          changeFolder: true,
                        );
                    Navigator.pop(sheetContext);
                  },
                )),
            ListTile(
              leading:
                  const Icon(Icons.folder_off_outlined, color: Colors.white70),
              title: const Text('Remove from folder',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                ref.read(libraryProvider.notifier).organizePlaylist(
                      playlist,
                      folderId: null,
                      changeFolder: true,
                    );
                Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCopyPlaylistDialog(Playlist source) async {
    final targets = ref
        .read(libraryProvider)
        .playlists
        .where((playlist) => playlist != source && playlist.name != source.name)
        .toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create another playlist first.')),
      );
      return;
    }
    final target = await showDialog<Playlist>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Add to another playlist'),
        children: targets
            .map((playlist) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, playlist),
                  child: Text(playlist.name),
                ))
            .toList(),
      ),
    );
    if (target == null || !mounted) return;
    try {
      await ref.read(libraryProvider.notifier).copyPlaylistTo(source, target);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added songs to ${target.name}.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add playlist: $error')),
        );
      }
    }
  }

  void _showDeleteDialog(Playlist playlist) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete playlist?',
            style: TextStyle(color: Colors.white)),
        content: Text('Delete "${playlist.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref.read(libraryProvider.notifier).deletePlaylistObj(playlist);
              Navigator.pop(dialogContext);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(playerProvider);
    final downloadState = ref.watch(downloadProvider);
    ref.watch(libraryProvider);
    final currentPlaylist = _currentPlaylist();
    final songs = currentPlaylist?.songs ?? _songs;
    final filtered = applyFilter(songs, _filter);
    final onlineSongs = songs.where((song) => !song.isLocal).toList();
    final downloadedCount =
        onlineSongs.where((song) => downloadState.isDownloaded(song.id)).length;
    final totalOnline = onlineSongs.length;
    final downloadingCount =
        onlineSongs.where((song) => downloadState.isDownloading(song.id)).length;
    final allDownloaded =
        onlineSongs.isNotEmpty && downloadedCount == onlineSongs.length;
    final isDownloading =
        onlineSongs.any((song) => downloadState.isDownloading(song.id));
    final anyDownloading = downloadingCount > 0;
    double avgProgress = 0;
    if (anyDownloading) {
      final total = onlineSongs
          .where((s) => downloadState.isDownloading(s.id))
          .fold<double>(0, (sum, s) => sum + downloadState.progressFor(s.id));
      avgProgress = total / downloadingCount;
    }

    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: true,
        child: CustomScrollView(
          slivers: [
            // ── Header ─────────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: _PlaylistHeader(
                title: widget.title,
                songs: songs,
                icon: widget.icon,
                creatorName: currentPlaylist?.ownerName ??
                    ref.watch(authServiceProvider).currentUser?.displayName ??
                    'You',
                shuffle: playerState.shuffle,
                onPlay: () => _playPlaylist(shuffle: false),
                onShuffle: () => _playPlaylist(shuffle: true),
                allDownloaded: allDownloaded,
                isDownloading: isDownloading,
                downloadedCount: downloadedCount,
                downloadingCount: downloadingCount,
                totalOnline: totalOnline,
                avgProgress: avgProgress,
                onDownload: _downloadPlaylist,
                onMore: currentPlaylist == null ? null : _showPlaylistDetails,
                onInvite: currentPlaylist == null
                    ? null
                    : () async {
                        final selected = await showCollaboratorInviteDialog(
                            context, ref, currentPlaylist);
                        if (selected == null || !context.mounted) return;
                        try {
                          await ref
                              .read(libraryProvider.notifier)
                              .inviteCollaborator(currentPlaylist, selected);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Playlist invitation sent.')),
                            );
                          }
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        }
                      },
              ),
            ),

            if (currentPlaylist != null)
              SliverToBoxAdapter(child: _buildPlaylistActions()),

            // ── Song list ─────────────────────────────────────────────────
            _editingOrder && currentPlaylist != null
                ? SliverReorderableList(
                    itemCount: _songs.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (oldIndex < newIndex) newIndex--;
                        final song = _songs.removeAt(oldIndex);
                        _songs.insert(newIndex, song);
                      });
                    },
                    itemBuilder: (context, index) {
                      final song = _songs[index];
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(song.id),
                        index: index,
                        child: SongTile(
                          song: song,
                          onTap: () => _playSong(song, _songs),
                          currentPlaylist: currentPlaylist,
                          trailing: const Icon(Icons.drag_handle,
                              color: Color(0xFFB3B3B3)),
                        ),
                      );
                    },
                  )
                : filtered.isEmpty
                    ? const SliverFillRemaining(
                        child: Center(
                          child: Text('No songs',
                              style: TextStyle(color: Color(0xFFB3B3B3))),
                        ),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) {
                            final song = filtered[i];
                            final isCurrent =
                                playerState.currentSong?.id == song.id;
                            return SongTile(
                              song: song,
                              isPlaying: isCurrent && playerState.isPlaying,
                              isSelected: isCurrent,
                              onTap: () => _playSong(song, filtered),
                              currentPlaylist: currentPlaylist,
                            );
                          },
                          childCount: filtered.length,
                        ),
                      ),

            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
      bottomNavigationBar: playerState.currentSong == null
          ? null
          : const SafeArea(
              top: false,
              child: MiniPlayer(),
            ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────

class _PlaylistHeader extends StatelessWidget {
  final String title;
  final List<Song> songs;
  final IconData? icon;
  final String creatorName;
  final bool shuffle;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final bool allDownloaded;
  final bool isDownloading;
  final int downloadedCount;
  final int downloadingCount;
  final int totalOnline;
  final double avgProgress;
  final VoidCallback onDownload;
  final VoidCallback? onInvite;
  final VoidCallback? onMore;

  const _PlaylistHeader({
    required this.title,
    required this.songs,
    required this.creatorName,
    required this.shuffle,
    required this.onPlay,
    required this.onShuffle,
    required this.allDownloaded,
    required this.isDownloading,
    required this.downloadedCount,
    required this.downloadingCount,
    required this.totalOnline,
    required this.avgProgress,
    required this.onDownload,
    this.onInvite,
    this.onMore,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    // Find first song with a real thumbnail
    final coverSong = songs.firstWhere(
      (s) => s.thumbnailUrl.isNotEmpty,
      orElse: () => songs.isEmpty ? _emptySong() : songs.first,
    );

    final totalDuration = songs.fold<Duration>(
      Duration.zero,
      (total, song) => total + song.duration,
    );

    return Container(
      color: const Color(0xFF0A0A0A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
                onPressed: () => Navigator.of(context).pop(),
              ),
              Center(
                child: coverSong.thumbnailUrl.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: coverSong.thumbnailUrl,
                          width: 180,
                          height: 180,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _iconBox(),
                        ),
                      )
                    : _iconBox(),
              ),
              const SizedBox(height: 18),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(
                children: [
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(0xFF535353),
                    child: Icon(Icons.person, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 8),
                  Text(creatorName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.public, color: Color(0xFFB3B3B3), size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${_formatDuration(totalDuration)} • ${songs.length} songs',
                    style:
                        const TextStyle(color: Color(0xFFB3B3B3), fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (onInvite != null)
                    IconButton(
                      icon: const Icon(Icons.person_add_alt_1,
                          color: Color(0xFFB3B3B3), size: 27),
                      tooltip: 'Invite to playlist',
                      onPressed: onInvite,
                    ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (isDownloading)
                          SizedBox(
                            width: 34,
                            height: 34,
                            child: CircularProgressIndicator(
                              value: avgProgress > 0 ? avgProgress : null,
                              strokeWidth: 2.2,
                              color: const Color(0xFF1DB954),
                              backgroundColor:
                                  const Color(0xFFB3B3B3).withValues(alpha: 0.2),
                            ),
                          ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            allDownloaded
                                ? Icons.download_done
                                : isDownloading
                                    ? Icons.downloading
                                    : Icons.download_outlined,
                            color: allDownloaded
                                ? const Color(0xFF1DB954)
                                : isDownloading
                                    ? const Color(0xFF1DB954)
                                    : const Color(0xFFB3B3B3),
                            size: 26,
                          ),
                          tooltip: allDownloaded
                              ? 'Playlist downloaded ($downloadedCount/$totalOnline)'
                              : isDownloading
                                  ? 'Downloading… ${downloadedCount + downloadingCount}/$totalOnline'
                                  : downloadedCount > 0
                                      ? 'Download remaining (${totalOnline - downloadedCount} songs)'
                                      : 'Download playlist ($totalOnline songs)',
                          onPressed:
                              isDownloading || allDownloaded ? null : onDownload,
                        ),
                      ],
                    ),
                  ),
                  if (totalOnline > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '$downloadedCount/$totalOnline',
                        style: TextStyle(
                          color: allDownloaded
                              ? const Color(0xFF1DB954)
                              : const Color(0xFFB3B3B3),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.more_vert,
                        color: Color(0xFFB3B3B3), size: 28),
                    onPressed: onMore,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.shuffle,
                        color: shuffle
                            ? const Color(0xFF1DB954)
                            : const Color(0xFF777777),
                        size: 30),
                    onPressed: onShuffle,
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF1DB954),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.play_arrow,
                          color: Colors.black, size: 32),
                      onPressed: onPlay,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBox() => Container(
        width: 110,
        height: 110,
        decoration: BoxDecoration(
          color: const Color(0xFF282828),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon ?? Icons.queue_music,
            color: const Color(0xFF3A3A3A), size: 52),
      );

  Song _emptySong() => Song(
      id: '',
      title: '',
      channelName: '',
      thumbnailUrl: '',
      duration: Duration.zero);
}

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}min';
  }
  return '${duration.inMinutes}min';
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, color: Colors.white, size: 18),
      label: Text(label),
      labelStyle:
          const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      backgroundColor: const Color(0xFF282828),
      onPressed: onTap,
    );
  }
}
