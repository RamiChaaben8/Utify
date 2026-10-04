// ============================================================
// screens/library_screen.dart  — Spotify-style mobile library
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/library_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/guest_session_provider.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../screens/playlist_screen.dart';
import '../services/firestore_service.dart';
import '../widgets/import_playlist_dialog.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/listen_party_controls.dart';
import '../desktop/widgets/invite_collaborator_dialog.dart';
import 'downloads_screen.dart';


/// Which songs to show in playlist/library screens.
enum SongFilter { all, local, online }

const _playlistVisibilityValues = ['private', 'friends', 'public'];

String _playlistVisibilityLabel(String value) {
  switch (value) {
    case 'friends':
      return 'Friends';
    case 'public':
      return 'Public';
    default:
      return 'Private';
  }
}

// Shared filter state so PlaylistScreen can read it too.
final songFilterProvider = StateProvider<SongFilter>((_) => SongFilter.all);

/// Applies [filter] to [songs], returning the matching subset.
List<Song> applyFilter(List<Song> songs, SongFilter filter) {
  switch (filter) {
    case SongFilter.all:
      return songs;
    case SongFilter.local:
      return songs.where((s) => s.isLocal).toList();
    case SongFilter.online:
      return songs.where((s) => !s.isLocal).toList();
  }
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  bool _gridView = false;
  final Set<String> _expandedFolders = <String>{};

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final isGuest = ref.watch(guestSessionProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Spotify-style header ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  // Profile avatar — tap to open account menu
                  const ProfileAvatar(),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Your Library',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Import playlist
                  IconButton(
                    icon: const Icon(Icons.playlist_add,
                        color: Colors.white, size: 26),
                    onPressed: () => showImportPlaylistDialog(context, ref),
                    tooltip: 'Import playlist',
                  ),
                  if (!isGuest) const PartyInviteButton(),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined,
                        color: Colors.white, size: 25),
                    onPressed: () => _showCreateFolderDialog(context),
                    tooltip: 'Create folder',
                  ),
                  // Create (+)
                  IconButton(
                    icon: const Icon(Icons.add, color: Colors.white, size: 28),
                    onPressed: () => _showCreatePlaylistDialog(context, ref),
                    tooltip: 'Create playlist',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Filter chips ──────────────────────────────────────────────
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _SpotifyChip(
                      label: 'Playlists', selected: true, onTap: () {}),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Recents bar + grid toggle ─────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.swap_vert,
                      color: Color(0xFFB3B3B3), size: 18),
                  const SizedBox(width: 4),
                  const Text(
                    'Recents',
                    style: TextStyle(
                        color: Color(0xFFB3B3B3),
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _gridView = !_gridView),
                    child: Icon(
                      _gridView ? Icons.list : Icons.grid_view,
                      color: const Color(0xFFB3B3B3),
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Loading bar ───────────────────────────────────────────────
            if (library.isLoading)
              const LinearProgressIndicator(
                backgroundColor: Color(0xFF1A1A1A),
                color: Color(0xFF1DB954),
                minHeight: 2,
              ),

            // ── Playlist list ─────────────────────────────────────────────
            Expanded(
              child: _gridView
                  ? _buildGridView(context, library)
                  : _buildListView(context, library),
            ),
          ],
        ),
      ),
    );
  }

  // ── List view ──────────────────────────────────────────────────────────────

  Widget _buildListView(
      BuildContext context, LibraryState library) {
    final items = _buildItems(library);
    if (items.isEmpty) {
      return _emptyState(context);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: items.length,
      itemBuilder: (_, i) => items[i],
    );
  }

  // ── Grid view ──────────────────────────────────────────────────────────────

  Widget _buildGridView(
      BuildContext context, LibraryState library) {
    final playlists = [...library.playlists]..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    if (playlists.isEmpty) return _emptyState(context);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: playlists.length,
      itemBuilder: (_, i) => _PlaylistGridCard(playlist: playlists[i]),
    );
  }

  List<Widget> _buildItems(LibraryState library) {
    final items = <Widget>[];

    // Liked Songs
    items.add(_SpotifyPlaylistTile(
      thumbnail: null,
      isFavourite: true,
      title: 'Liked Songs',
      subtitle: 'Playlist • ${library.likedSongs.length} songs',
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlaylistScreen(
          title: 'Liked Songs',
          songs: library.likedSongs,
          icon: Icons.favorite,
        ),
      )),
    ));

    // Downloads
    items.add(_SpotifyPlaylistTile(
      thumbnail: null,
      isFavourite: false,
      customIcon: const Icon(Icons.cloud_done_rounded,
          color: Color(0xFF1DB954), size: 24),
      title: 'Downloads',
      subtitle: 'Offline songs',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DownloadsScreen()),
      ),
    ));

    // Recently Played

    if (library.recentlyPlayed.isNotEmpty) {
      items.add(_SpotifyPlaylistTile(
        thumbnail: library.recentlyPlayed.first.thumbnailUrl,
        title: 'Recently Played',
        subtitle: 'Playlist • ${library.recentlyPlayed.length} songs',
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlaylistScreen(
            title: 'Recently Played',
            songs: library.recentlyPlayed,
            icon: Icons.history,
          ),
        )),
      ));
    }

    final unfiled = library.playlists
        .where((playlist) => playlist.folderId == null)
        .toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    for (final pl in unfiled) {
      items.add(_SpotifyPlaylistTile(
        playlist: pl,
        thumbnail: pl.coverThumbnail,
        title: pl.name,
        subtitle: 'Playlist • ${pl.songs.length} songs',
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlaylistScreen(
            title: pl.name,
            songs: pl.songs,
            playlist: pl,
          ),
        )),
        onMoreTap: () => _showPlaylistOptions(context, pl),
      ));
    }

    for (final folder in library.folders) {
      final playlists = library.playlists
          .where((playlist) => playlist.folderId == folder)
          .toList();
      playlists.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      final expanded = _expandedFolders.contains(folder);
      items.add(ListTile(
        leading: Icon(
          expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
          color: const Color(0xFFB3B3B3),
        ),
        title: Text(folder,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(
            '${playlists.length} playlist${playlists.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Color(0xFFB3B3B3))),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.more_vert, color: Color(0xFFB3B3B3)),
              onPressed: () => _showFolderOptions(context, folder),
            ),
            Icon(
              expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              color: const Color(0xFFB3B3B3),
            ),
          ],
        ),
        onTap: () => setState(() {
          if (expanded) {
            _expandedFolders.remove(folder);
          } else {
            _expandedFolders.add(folder);
          }
        }),
      ));
      if (expanded) {
        for (final playlist in playlists) {
          items.add(Padding(
            padding: const EdgeInsets.only(left: 28),
            child: _SpotifyPlaylistTile(
              playlist: playlist,
              thumbnail: playlist.coverThumbnail,
              title: playlist.name,
              subtitle: 'Playlist • ${playlist.songs.length} songs',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlaylistScreen(
                  title: playlist.name,
                  songs: playlist.songs,
                  playlist: playlist,
                ),
              )),
              onMoreTap: () => _showPlaylistOptions(context, playlist),
            ),
          ));
        }
      }
    }

    return items;
  }

  void _showCreateFolderDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('New folder', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              await ref.read(libraryProvider.notifier).createFolder(name);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Create',
                style: TextStyle(color: Color(0xFF1DB954))),
          ),
        ],
      ),
    );
  }

  void _showFolderOptions(BuildContext context, String folder) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title:
                  const Text('Rename', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                _renameFolder(context, folder);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete folder',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                await ref.read(libraryProvider.notifier).deleteFolder(folder);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _renameFolder(BuildContext context, String folder) {
    final controller = TextEditingController(text: folder);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              await ref
                  .read(libraryProvider.notifier)
                  .renameFolder(folder, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.library_music, size: 64, color: Color(0xFF3A3A3A)),
            const SizedBox(height: 16),
            const Text(
              'Build your library',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Like songs, download them, or create playlists.',
              style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    var visibility = 'private';
    var collaborative = false;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                items: _playlistVisibilityValues
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(_playlistVisibilityLabel(v)),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => visibility = v ?? 'private'),
              ),
              StatefulBuilder(
                builder: (context, setInnerState) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: collaborative,
                  title: const Text('Collaborative',
                      style: TextStyle(color: Colors.white)),
                  onChanged: (value) {
                    setInnerState(() => collaborative = value ?? false);
                    setState(() {});
                  },
                ),
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

  void _showPlaylistOptions(BuildContext context, Playlist pl) {
    final isOwner = pl.sharedId == null ||
        pl.ownerUid == ref.read(authServiceProvider).currentUser?.uid;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF282828),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF555555),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.white70),
              title:
                  const Text('Rename', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context, pl);
              },
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.public_outlined, color: Colors.white70),
              title: Text(
                  'Visibility: ${_playlistVisibilityLabel(pl.visibility)}',
                  style: const TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showVisibilityMenu(context, pl);
              },
            ),
            if (isOwner)
              ListTile(
              leading: Icon(
                pl.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: Colors.white70,
              ),
              title: Text(pl.pinned ? 'Unpin playlist' : 'Pin playlist',
                  style: const TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                ref.read(libraryProvider.notifier).organizePlaylist(
                      pl,
                      pinned: !pl.pinned,
                    );
              },
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.folder_outlined, color: Colors.white70),
              title: const Text('Move to folder',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showPlaylistFolderPicker(context, pl);
              },
            ),
            if (isOwner)
              ListTile(
              leading: const Icon(Icons.playlist_add, color: Colors.white70),
              title: const Text('Add to another playlist',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showCopyPlaylistDialog(context, pl);
              },
            ),
            if (isOwner && !ref.read(guestSessionProvider))
              ListTile(
              leading:
                  const Icon(Icons.group_add_outlined, color: Colors.white70),
              title: Text(
                pl.sharedId == null
                    ? 'Make collaborative'
                    : 'Invite collaborator',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(context);
                if (pl.sharedId == null) {
                  final sharedId = await ref
                      .read(libraryProvider.notifier)
                      .makePlaylistCollaborative(pl);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Playlist is now collaborative.')),
                  );
                  if (sharedId != null && mounted) {
                    final updated = Playlist(
                      name: pl.name,
                      songs: pl.songs,
                      createdAt: pl.createdAt,
                      description: pl.description,
                      visibility: pl.visibility,
                      pinned: pl.pinned,
                      folderId: pl.folderId,
                      sharedId: sharedId,
                      ownerUid: ref
                          .read(authServiceProvider)
                          .currentUser
                          ?.uid,
                    );
                    playlistFirestoreIds[updated] = sharedId;
                    final uid = await showCollaboratorInviteDialog(
                        context, ref, updated);
                    if (uid != null && mounted) {
                      await ref
                          .read(libraryProvider.notifier)
                          .inviteCollaborator(updated, uid);
                    }
                  }
                } else {
                  final uid =
                      await showCollaboratorInviteDialog(context, ref, pl);
                  if (uid != null && mounted) {
                    await ref
                        .read(libraryProvider.notifier)
                        .inviteCollaborator(pl, uid);
                  }
                }
              },
            ),
            ListTile(
              leading: Icon(
                isOwner ? Icons.delete_outline : Icons.logout,
                color: isOwner ? Colors.redAccent : Colors.white70,
              ),
              title: Text(isOwner ? 'Delete' : 'Quit playlist',
                  style: TextStyle(
                      color: isOwner ? Colors.redAccent : Colors.white)),
              onTap: () {
                Navigator.pop(context);
                if (isOwner) {
                  _showDeleteDialog(context, pl);
                } else {
                  _quitPlaylist(pl);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _quitPlaylist(Playlist playlist) async {
    try {
      await ref
          .read(libraryProvider.notifier)
          .quitCollaborativePlaylist(playlist);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You left the playlist.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not leave playlist: $error')),
        );
      }
    }
  }

  void _showPlaylistFolderPicker(BuildContext context, Playlist playlist) {
    final folders = ref.read(libraryProvider).folders;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Move playlist to folder',
                  style: TextStyle(color: Colors.white)),
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

  Future<void> _showCopyPlaylistDialog(
      BuildContext context, Playlist source) async {
    final targets = ref
        .read(libraryProvider)
        .playlists
        .where((playlist) =>
            playlist.sharedId != source.sharedId &&
            playlist.firestoreId != source.firestoreId &&
            playlist.key != source.key &&
            playlist.name != source.name)
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

  void _showRenameDialog(BuildContext context, Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Rename Playlist',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFFB3B3B3)))),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                ref
                    .read(libraryProvider.notifier)
                    .renamePlaylistObj(playlist, controller.text.trim());
                Navigator.pop(context);
              }
            },
            child:
                const Text('Save', style: TextStyle(color: Color(0xFF1DB954))),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, Playlist playlist) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete Playlist?',
            style: TextStyle(color: Colors.white)),
        content: Text('Delete "${playlist.name}"?',
            style: const TextStyle(color: Color(0xFFB3B3B3))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFFB3B3B3)))),
          TextButton(
            onPressed: () {
              ref.read(libraryProvider.notifier).deletePlaylistObj(playlist);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showVisibilityMenu(BuildContext context, Playlist playlist) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in ['private', 'friends', 'public'])
              RadioListTile<String>(
                value: v,
                groupValue: playlist.visibility,
                title: Text(_playlistVisibilityLabel(v),
                    style: const TextStyle(color: Colors.white)),
                onChanged: (next) {
                  if (next != null) {
                    ref
                        .read(libraryProvider.notifier)
                        .setPlaylistVisibility(playlist, next);
                    Navigator.pop(context);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Spotify playlist tile ─────────────────────────────────────────────────────

class _SpotifyPlaylistTile extends StatelessWidget {
  final String? thumbnail;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onMoreTap;
  final Playlist? playlist;
  final bool isFavourite;
  final Widget? customIcon;

  const _SpotifyPlaylistTile({
    required this.thumbnail,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onMoreTap,
    this.playlist,
    this.isFavourite = false,
    this.customIcon,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: onTap,
      leading: _buildThumbnail(),
      title: Text(
        title,
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: onMoreTap != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (playlist?.pinned == true)
                  const Icon(Icons.push_pin,
                      color: Color(0xFF1DB954), size: 18),
                IconButton(
                  icon: const Icon(Icons.more_vert, color: Color(0xFFB3B3B3)),
                  onPressed: onMoreTap,
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildThumbnail() {
    if (customIcon != null) {
      return Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF1A2A1A),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(child: customIcon!),
      );
    }
    if (isFavourite) {
      return Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF4A90D9), Color(0xFF9B59B6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.favorite, color: Colors.white, size: 28),
      );
    }

    if (thumbnail != null && thumbnail!.isNotEmpty) {
      // Multi-thumbnail mosaic for playlists with songs
      if (playlist != null && playlist!.songs.length >= 4) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: 56,
            height: 56,
            child: GridView.count(
              crossAxisCount: 2,
              physics: const NeverScrollableScrollPhysics(),
              children: playlist!.songs.take(4).map((s) {
                return CachedNetworkImage(
                  imageUrl: s.thumbnailUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      Container(color: const Color(0xFF282828)),
                  errorWidget: (_, __, ___) =>
                      Container(color: const Color(0xFF282828)),
                );
              }).toList(),
            ),
          ),
        );
      }

      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedNetworkImage(
          imageUrl: thumbnail!,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          placeholder: (_, __) => _placeholder(),
          errorWidget: (_, __, ___) => _placeholder(),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() => Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF282828),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.music_note, color: Color(0xFF3A3A3A), size: 26),
      );
}

// ─── Grid card ─────────────────────────────────────────────────────────────────

class _PlaylistGridCard extends StatelessWidget {
  final Playlist playlist;
  const _PlaylistGridCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlaylistScreen(
          title: playlist.name,
          songs: playlist.songs,
          playlist: playlist,
        ),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 1,
              child: _buildCover(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          Text(
            '${playlist.songs.length} songs',
            maxLines: 1,
            style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildCover() {
    if (playlist.songs.length >= 4) {
      return GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: playlist.songs.take(4).map((s) {
          return CachedNetworkImage(
            imageUrl: s.thumbnailUrl,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: const Color(0xFF282828)),
            errorWidget: (_, __, ___) =>
                Container(color: const Color(0xFF282828)),
          );
        }).toList(),
      );
    }
    if (playlist.coverThumbnail != null) {
      return CachedNetworkImage(
        imageUrl: playlist.coverThumbnail!,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: const Color(0xFF282828)),
        errorWidget: (_, __, ___) => Container(color: const Color(0xFF282828)),
      );
    }
    return Container(
      color: const Color(0xFF282828),
      child: const Icon(Icons.music_note, color: Color(0xFF3A3A3A), size: 40),
    );
  }
}

// ─── Spotify pill chip ─────────────────────────────────────────────────────────

class _SpotifyChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SpotifyChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.white : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
