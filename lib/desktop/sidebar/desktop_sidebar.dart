// ============================================================
// desktop/sidebar/desktop_sidebar.dart
// Left panel — playlists + library navigation.
//
// • Right-click a playlist → context menu (Add to Queue, Rename, Remove)
// • ··· button on each playlist tile → same menu
// • Liked Songs tile → opens like a playlist (read-only, no edit/remove)
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../providers/library_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../providers/player_provider.dart';
import '../../providers/guest_session_provider.dart';
import '../theme/desktop_theme.dart';
import '../theme/ui_sizes.dart';
import '../widgets/invite_collaborator_dialog.dart';
import '../../widgets/import_playlist_dialog.dart';

class DesktopSidebar extends ConsumerStatefulWidget {
  final Playlist? selectedPlaylist;
  final void Function(Playlist?) onPlaylistSelected;
  final VoidCallback? onDownloadsSelected;

  /// Width to render at. When null the theme default for the current window
  /// is used instead.
  final double? width;

  /// Whether the sidebar is showing its collapsed icon rail. Driven by the
  /// shell so that dragging the divider narrower than the minimum expanded
  /// width collapses it, and so the choice is remembered alongside the width.
  final bool collapsed;

  /// Called when the user taps the collapse/expand control in the header or on
  /// the rail.
  final ValueChanged<bool> onCollapsedChanged;

  const DesktopSidebar({
    super.key,
    required this.selectedPlaylist,
    required this.onPlaylistSelected,
    this.onDownloadsSelected,
    this.width,
    this.collapsed = false,
    this.onCollapsedChanged = _ignoreCollapsedChanged,
  });

  static void _ignoreCollapsedChanged(bool _) {}

  @override
  ConsumerState<DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends ConsumerState<DesktopSidebar> {
  final Set<String> _expandedFolders = <String>{};

  /// The shell owns the collapsed state so it can be driven by the resize
  /// divider as well as the header button.
  bool get _collapsed => widget.collapsed;

  /// Rail width, shared with the shell so the two never disagree.
  static const double _kCollapsedWidth = 64.0;

  /// Returns true if [a] and [b] refer to the same playlist.
  /// Prefers Firestore ID comparison, falls back to Hive key, then name+createdAt.
  bool _isSamePlaylist(Playlist a, Playlist b) {
    final aFsId = a.firestoreId;
    final bFsId = b.firestoreId;
    if (aFsId != null && bFsId != null) return aFsId == bFsId;
    final aKey = a.key;
    final bKey = b.key;
    if (aKey != null && bKey != null) return aKey == bKey;
    return a.name == b.name && a.createdAt == b.createdAt;
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final layout = context.appTheme.layout;

    final likedPlaylist = library.likedSongs.isNotEmpty
        ? Playlist(name: 'Liked Songs', songs: library.likedSongs)
        : null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: _collapsed
          ? _kCollapsedWidth
          : (widget.width ??
              layout.sidebarWidthFor(MediaQuery.sizeOf(context).width)),
      decoration: BoxDecoration(
        color: context.appTheme.sidebar,
        borderRadius: context.appTheme.isVerdantNightDesktop
            ? BorderRadius.circular(layout.panelRadius)
            : BorderRadius.only(
                topRight: Radius.circular(layout.panelRadius),
                bottomRight: Radius.circular(layout.panelRadius),
              ),
      ),
      clipBehavior: Clip.antiAlias,
      child: _collapsed
          ? _buildCollapsed(likedPlaylist, library)
          : _buildExpanded(likedPlaylist, library),
    );
  }

  // ── Collapsed: icon-only column ──────────────────────────────────────────

  Widget _buildCollapsed(Playlist? likedPlaylist, LibraryState library) {
    return Column(
      children: [
        SizedBox(height: 16),

        // Library icon — tap to expand
        Tooltip(
          message: 'Expand library',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.onCollapsedChanged(false),
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.library_music,
                  color: context.appTheme.iconColor(context.appTheme.button),
                  size: 24),
            ),
          ),
        ),

        SizedBox(height: 8),
        Divider(
            color: context.appTheme.dividerColor, height: 1, thickness: 0.5),
        SizedBox(height: 8),

        // Liked Songs icon
        if (likedPlaylist != null)
          Tooltip(
            message: 'Liked Songs',
            child: _IconOnlyTile(
              icon: Icons.favorite,
              // `misc` was a dark red on a dark red tile in Verdant Night
              // (~1.4:1) — effectively invisible. Neutral grey matches the
              // fallback every other thumbnail-less playlist tile uses.
              color: context.appTheme.subtext,
              bgColor: context.appTheme.misc.withValues(alpha: 0.35),
              isActive: widget.selectedPlaylist?.name == 'Liked Songs',
              onTap: () {
                final active = widget.selectedPlaylist?.name == 'Liked Songs';
                widget.onPlaylistSelected(active ? null : likedPlaylist);
              },
            ),
          ),

        if (likedPlaylist != null) SizedBox(height: 4),

        // Playlist icons
        Expanded(
          child: ListView(
            padding: EdgeInsets.symmetric(vertical: 4),
            children: library.playlists.map((pl) {
              final thumbUrl =
                  pl.songs.isNotEmpty ? pl.songs.first.thumbnailUrl : '';
              final isActive = widget.selectedPlaylist != null &&
                  _isSamePlaylist(widget.selectedPlaylist!, pl);
              return Tooltip(
                message: pl.name,
                child: _IconOnlyTile(
                  thumbUrl: thumbUrl,
                  isActive: isActive,
                  onTap: () => widget.onPlaylistSelected(isActive ? null : pl),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── Expanded: full sidebar ───────────────────────────────────────────────

  Widget _buildExpanded(Playlist? likedPlaylist, LibraryState library) {
    final folders = <String, List<Playlist>>{};
    final unfiled = <Playlist>[];
    for (final folder in library.folders) {
      folders[folder] = [];
    }
    for (final playlist in library.playlists) {
      final folder = playlist.folderId;
      if (folder == null || folder.isEmpty) {
        unfiled.add(playlist);
      } else {
        folders.putIfAbsent(folder, () => []).add(playlist);
      }
    }
    final sorted = (List<Playlist> items) => items
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    Widget playlistTile(Playlist playlist) {
      final isActive = widget.selectedPlaylist != null &&
          _isSamePlaylist(widget.selectedPlaylist!, playlist);
      return _PlaylistTile(
        playlist: playlist,
        isActive: isActive,
        onTap: () => widget.onPlaylistSelected(isActive ? null : playlist),
        onOpen: () => widget.onPlaylistSelected(playlist),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ─────────────────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              // Library icon — tap to collapse
              Tooltip(
                message: 'Collapse library',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.onCollapsedChanged(true),
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.library_music,
                        color:
                            context.appTheme.iconColor(context.appTheme.button),
                        size: 22),
                  ),
                ),
              ),
              SizedBox(width: 8),
              // Flexible so a narrow sidebar ellipsises the title instead of
              // overflowing — the header also holds three action buttons.
              Flexible(
                child: Text(
                  'Your Library',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: context.appTheme.isVerdantNightDesktop
                        ? context.appTheme.text
                        : context.appTheme.button,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Spacer(),
              Tooltip(
                message: 'Create playlist',
                child: IconButton(
                  onPressed: () => _showCreatePlaylistDialog(context),
                  icon: Icon(Icons.add,
                      size: 18,
                      color:
                          context.appTheme.iconColor(context.appTheme.button)),
                  padding: EdgeInsets.all(6),
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  splashRadius: 16,
                ),
              ),
              Tooltip(
                message: 'Import playlist',
                child: IconButton(
                  onPressed: () => showImportPlaylistDialog(context, ref),
                  icon: Icon(Icons.playlist_add,
                      size: 18,
                      color:
                          context.appTheme.iconColor(context.appTheme.button)),
                  padding: EdgeInsets.all(6),
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  splashRadius: 16,
                ),
              ),
              Tooltip(
                message: 'Create folder',
                child: IconButton(
                  onPressed: () => _showCreateFolderDialog(context),
                  icon: Icon(Icons.create_new_folder_outlined,
                      size: 18,
                      color:
                          context.appTheme.iconColor(context.appTheme.button)),
                  padding: EdgeInsets.all(6),
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  splashRadius: 16,
                ),
              ),
            ],
          ),
        ),

        // ── Filter chip ────────────────────────────────────────────
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: context.appTheme.tabActive,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Playlists',
              style: TextStyle(
                color: context.appTheme.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),

        Divider(
            color: context.appTheme.dividerColor, height: 16, thickness: 0.5),

        // ── List ───────────────────────────────────────────────────
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: 8),
            children: [
              if (likedPlaylist != null)
                _LikedSongsTile(
                  playlist: likedPlaylist,
                  isActive: widget.selectedPlaylist?.name == 'Liked Songs',
                  onTap: () {
                    final active =
                        widget.selectedPlaylist?.name == 'Liked Songs';
                    widget.onPlaylistSelected(active ? null : likedPlaylist);
                  },
                ),
              if (likedPlaylist != null)
                Divider(
                    color: context.appTheme.dividerColor,
                    height: 16,
                    thickness: 0.5),
              // ── Downloads ────────────────────────────────────────────
              if (widget.onDownloadsSelected != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.cloud_done_rounded,
                      color: Color(0xFF1DB954), size: 20),
                  title: const Text(
                    'Downloads',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  onTap: widget.onDownloadsSelected,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
              if (widget.onDownloadsSelected != null)
                Divider(
                    color: context.appTheme.dividerColor,
                    height: 16,
                    thickness: 0.5),

              if (library.playlists.isEmpty && library.folders.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No playlists yet.\nTap + Create to add one.',
                    style: TextStyle(
                        color: context.appTheme.subtext, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                )
              else ...[
                // ── Drop here to remove from folder ──────────────
                DragTarget<Playlist>(
                  onWillAcceptWithDetails: (details) {
                    // Accept only playlists that are currently in a folder.
                    // Check live state, not the stale drag data object.
                    final library = ref.read(libraryProvider);
                    final draggedId = details.data.firestoreId ??
                        details.data.sharedId ??
                        details.data.key?.toString();
                    Playlist? live;
                    try {
                      live = library.playlists.firstWhere((p) {
                        if (draggedId != null) {
                          if (p.firestoreId == draggedId) return true;
                          if (p.sharedId == draggedId) return true;
                          if (p.key?.toString() == draggedId) return true;
                        }
                        return p.name == details.data.name &&
                            p.createdAt == details.data.createdAt;
                      });
                    } catch (_) {
                      live = null;
                    }
                    return (live ?? details.data).folderId != null;
                  },
                  onAcceptWithDetails: (details) {
                    final library = ref.read(libraryProvider);
                    final draggedId = details.data.firestoreId ??
                        details.data.sharedId ??
                        details.data.key?.toString();
                    late Playlist live;
                    try {
                      live = library.playlists.firstWhere((p) {
                        if (draggedId != null) {
                          if (p.firestoreId == draggedId) return true;
                          if (p.sharedId == draggedId) return true;
                          if (p.key?.toString() == draggedId) return true;
                        }
                        return p.name == details.data.name &&
                            p.createdAt == details.data.createdAt;
                      });
                    } catch (_) {
                      live = details.data;
                    }
                    ref.read(libraryProvider.notifier).organizePlaylist(
                          live,
                          folderId: null,
                          changeFolder: true,
                        );
                  },
                  builder: (context, candidates, _) {
                    final active = candidates.isNotEmpty;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: active ? 40 : 4,
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        color: active
                            ? (context.appTheme.isVerdantNightDesktop
                                ? context.appTheme.selectedRow
                                    .withValues(alpha: 0.6)
                                : context.appTheme.button
                                    .withValues(alpha: 0.15))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: active
                            ? Border.all(
                                color: context.appTheme
                                    .iconColor(context.appTheme.text)
                                    .withValues(alpha: 0.5),
                                width: 1.5,
                              )
                            : null,
                      ),
                      child: active
                          ? Center(
                              child: Text(
                                'Drop here to remove from folder',
                                style: TextStyle(
                                  color: context.appTheme.text,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          : null,
                    );
                  },
                ),
                ...sorted(unfiled).map(playlistTile),
                ...folders.entries.map((entry) {
                  final expanded = _expandedFolders.contains(entry.key);
                  return _FolderSection(
                    name: entry.key,
                    playlists: sorted(entry.value),
                    expanded: expanded,
                    playlistTile: playlistTile,
                    onToggle: () => setState(() {
                      if (expanded) {
                        _expandedFolders.remove(entry.key);
                      } else {
                        _expandedFolders.add(entry.key);
                      }
                    }),
                  );
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showCreatePlaylistDialog(BuildContext context) async {
    final controller = TextEditingController();
    var visibility = 'private';
    var collaborative = false;
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.appTheme.card,
        insetPadding: EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        title: Text('New Playlist',
            style: TextStyle(color: context.appTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              style: TextStyle(color: context.appTheme.text),
              decoration: InputDecoration(
                hintText: 'Playlist name',
                hintStyle: TextStyle(color: context.appTheme.subtext),
                filled: true,
                fillColor: context.appTheme.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (value) {
                final name = value.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(ctx, (name, collaborative));
                }
              },
            ),
            DropdownButtonFormField<String>(
              value: visibility,
              decoration: InputDecoration(labelText: 'Privacy'),
              items: const [
                DropdownMenuItem(value: 'private', child: Text('Private')),
                DropdownMenuItem(value: 'friends', child: Text('Friends')),
                DropdownMenuItem(value: 'public', child: Text('Public')),
              ],
              onChanged: (value) => visibility = value ?? 'private',
            ),
            if (!ref.read(guestSessionProvider))
              StatefulBuilder(
                builder: (context, setDialogState) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: collaborative,
                  title: Text('Collaborative playlist',
                      style: TextStyle(color: context.appTheme.text)),
                  subtitle: Text('Invite friends to add songs',
                      style: TextStyle(color: context.appTheme.subtext)),
                  onChanged: (value) =>
                      setDialogState(() => collaborative = value ?? false),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: context.appTheme.subtext)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: context.appTheme.isVerdantNightDesktop
                    ? context.appTheme.text
                    : context.appTheme.button,
                foregroundColor: context.appTheme.isVerdantNightDesktop
                    ? context.appTheme.main
                    : context.appTheme.text),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx, (name, collaborative));
              }
            },
            // No explicit TextStyle: the child's colour would override the
            // button's foregroundColor, which is already dark-on-lime here.
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.$1.isNotEmpty) {
      try {
        await ref.read(libraryProvider.notifier).createPlaylist(result.$1,
            visibility: visibility, collaborative: result.$2);
        if (result.$2 && mounted) {
          _showMessage(
              'Collaborative playlist created. Open its menu to invite a friend.');
        }
      } catch (error) {
        if (mounted) {
          _showMessage('Could not create playlist: $error');
        }
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showCreateFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.appTheme.card,
        title:
            Text('New folder', style: TextStyle(color: context.appTheme.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: context.appTheme.text),
          decoration: InputDecoration(
            hintText: 'Folder name',
            hintStyle: TextStyle(color: context.appTheme.subtext),
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: context.appTheme.subtext)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await ref.read(libraryProvider.notifier).createFolder(name);
      setState(() => _expandedFolders.add(name));
    } catch (error) {
      _showMessage('Could not create folder: $error');
    }
  }

  Future<void> _movePlaylistToFolder(Playlist playlist, String folder) async {
    try {
      await ref
          .read(libraryProvider.notifier)
          .organizePlaylist(playlist, folderId: folder, changeFolder: true);
    } catch (error) {
      _showMessage('Could not move playlist: $error');
    }
  }

  Future<void> _showFolderMenu(String name, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      // Matches the playlist menu right next to it — without these the folder
      // menu fell back to `surface` == `main`, invisible against the sidebar.
      color: context.appTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.appTheme.dividerColor),
      ),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('Rename folder')),
        PopupMenuItem(value: 'delete', child: Text('Delete folder')),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: name);
      final next = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename folder'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Save')),
          ],
        ),
      );
      controller.dispose();
      if (next != null && next.isNotEmpty) {
        await ref.read(libraryProvider.notifier).renameFolder(name, next);
        setState(() {
          if (_expandedFolders.remove(name)) _expandedFolders.add(next);
        });
      }
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete folder?'),
          content: Text('Playlists in "$name" will stay in your library.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (confirmed == true) {
        await ref.read(libraryProvider.notifier).deleteFolder(name);
        setState(() => _expandedFolders.remove(name));
      }
    }
  }
}

class _FolderSection extends StatelessWidget {
  final String name;
  final List<Playlist> playlists;
  final bool expanded;
  final Widget Function(Playlist) playlistTile;
  final VoidCallback onToggle;

  const _FolderSection({
    required this.name,
    required this.playlists,
    required this.expanded,
    required this.playlistTile,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Column(
      children: [
        DragTarget<Playlist>(
          onWillAcceptWithDetails: (details) {
            // Check live state so we don't use a stale folderId on drag data.
            final sidebarState =
                context.findAncestorStateOfType<_DesktopSidebarState>();
            if (sidebarState == null) return false;
            final library = sidebarState.ref.read(libraryProvider);
            final draggedId = details.data.firestoreId ??
                details.data.sharedId ??
                details.data.key?.toString();
            Playlist? live;
            try {
              live = library.playlists.firstWhere((p) {
                if (draggedId != null) {
                  if (p.firestoreId == draggedId) return true;
                  if (p.sharedId == draggedId) return true;
                  if (p.key?.toString() == draggedId) return true;
                }
                return p.name == details.data.name &&
                    p.createdAt == details.data.createdAt;
              });
            } catch (_) {
              live = null;
            }
            // Don't accept if already in this folder.
            return (live ?? details.data).folderId != name;
          },
          onAcceptWithDetails: (details) {
            final state =
                context.findAncestorStateOfType<_DesktopSidebarState>();
            if (state == null) return;
            // Use the live playlist from provider state by matching IDs so we
            // never pass a stale drag-data object into organizePlaylist.
            final draggedId = details.data.firestoreId ??
                details.data.sharedId ??
                details.data.key?.toString();
            final library = state.ref.read(libraryProvider);
            final live = library.playlists.firstWhere(
              (p) {
                if (draggedId != null) {
                  if (p.firestoreId == draggedId) return true;
                  if (p.sharedId == draggedId) return true;
                  if (p.key?.toString() == draggedId) return true;
                }
                return p.name == details.data.name &&
                    p.createdAt == details.data.createdAt;
              },
              orElse: () => details.data,
            );
            state._movePlaylistToFolder(live, name);
          },
          builder: (context, candidates, _) => GestureDetector(
            onSecondaryTapUp: (details) {
              final state =
                  context.findAncestorStateOfType<_DesktopSidebarState>();
              state?._showFolderMenu(name, details.globalPosition);
            },
            child: Material(
              color: candidates.isNotEmpty ? theme.selectedRow : theme.card,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: theme.misc.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.folder_outlined,
                            color: theme.subtext, size: 25),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.isVerdantNightDesktop
                                    ? theme.text
                                    : theme.button,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${playlists.length} playlist${playlists.length == 1 ? '' : 's'}',
                              style:
                                  TextStyle(color: theme.subtext, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: theme.subtext,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(children: playlists.map(playlistTile).toList()),
          ),
      ],
    );
  }
}

// Top-level enum — cannot be declared inside a class in Dart
// ─── Icon-only tile (collapsed mode) ─────────────────────────────────────────

class _IconOnlyTile extends StatefulWidget {
  final IconData? icon;
  final Color? color;
  final Color? bgColor;
  final String? thumbUrl;
  final bool isActive;
  final VoidCallback onTap;

  const _IconOnlyTile({
    this.icon,
    this.color,
    this.bgColor,
    this.thumbUrl,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_IconOnlyTile> createState() => _IconOnlyTileState();
}

class _IconOnlyTileState extends State<_IconOnlyTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: widget.isActive
                ? context.appTheme.selectedRow
                : _hovered
                    ? context.appTheme.highlight
                    : context.appTheme.main.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(8),
            border: widget.isActive
                ? Border.all(
                    // iconColor(text) demotes to plain grey in Verdant Night,
                    // so the selected-playlist ring lost its accent there.
                    color: context.appTheme.nowPlayingAccent.withValues(alpha: 0.5),
                    width: 1)
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: widget.thumbUrl != null && widget.thumbUrl!.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: widget.thumbUrl!,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _iconBox(),
                    errorWidget: (_, __, ___) => _iconBox(),
                  )
                : _iconBox(),
          ),
        ),
      ),
    );
  }

  Widget _iconBox() {
    return Container(
      color: widget.bgColor ?? context.appTheme.misc.withValues(alpha: 0.7),
      child: Icon(
        widget.icon ?? Icons.queue_music,
        color: widget.color ?? context.appTheme.subtext.withValues(alpha: 0.54),
        size: 22,
      ),
    );
  }
}

// ─── Playlist tile with right-click + ··· menu ───────────────────────────────

class _PlaylistTile extends ConsumerStatefulWidget {
  final Playlist playlist;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  const _PlaylistTile({
    required this.playlist,
    required this.isActive,
    required this.onTap,
    required this.onOpen,
  });

  @override
  ConsumerState<_PlaylistTile> createState() => _PlaylistTileState();
}

class _PlaylistTileState extends ConsumerState<_PlaylistTile> {
  @override
  Widget build(BuildContext context) {
    final thumbUrl = widget.playlist.songs.isNotEmpty
        ? widget.playlist.songs.first.thumbnailUrl
        : '';

    return Draggable<Playlist>(
      data: widget.playlist,
      feedback: Material(
        color: context.appTheme.card,
        child: SizedBox(
          width: 260,
          child: ListTile(
            leading: Icon(Icons.queue_music,
                color: context.appTheme.iconDefault),
            title: Text(widget.playlist.name,
                style: TextStyle(color: context.appTheme.text)),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: _buildTile(context, thumbUrl),
      ),
      child: _buildTile(context, thumbUrl),
    );
  }

  Widget _buildTile(BuildContext context, String thumbUrl) {
    final layout = context.appTheme.layout;
    return MouseRegion(
      child: GestureDetector(
        // Right-click opens context menu
        onSecondaryTapUp: (d) => _showMenu(context, d.globalPosition),
        child: Material(
          color: widget.isActive
              ? context.appTheme.selectedRow
              : context.appTheme.main.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(layout.cardRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(layout.cardRadius),
            onTap: widget.onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical:
                    (layout.libraryRowHeight - layout.libraryThumbnailSize) / 2,
              ),
              child: Row(
                children: [
                  // Thumbnail
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(layout.libraryThumbnailRadius),
                    child: thumbUrl.isEmpty
                        ? Container(
                            width: layout.libraryThumbnailSize,
                            height: layout.libraryThumbnailSize,
                            color: context.appTheme.misc.withValues(alpha: 0.7),
                            child: Icon(Icons.queue_music,
                                color: context.appTheme.subtext
                                    .withValues(alpha: 0.54),
                                size: 22),
                          )
                        : CachedNetworkImage(
                            imageUrl: thumbUrl,
                            width: layout.libraryThumbnailSize,
                            height: layout.libraryThumbnailSize,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                                width: layout.libraryThumbnailSize,
                                height: layout.libraryThumbnailSize,
                                color: context.appTheme.misc
                                    .withValues(alpha: 0.7)),
                            errorWidget: (_, __, ___) => Container(
                              width: layout.libraryThumbnailSize,
                              height: layout.libraryThumbnailSize,
                              color:
                                  context.appTheme.misc.withValues(alpha: 0.7),
                              child: Icon(Icons.queue_music,
                                  color: context.appTheme.subtext
                                      .withValues(alpha: 0.54),
                                  size: 22),
                            ),
                          ),
                  ),
                  SizedBox(width: 12),

                  // Name + count
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.playlist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.isActive
                                ? context.appTheme.nowPlayingAccent
                                : context.appTheme.text,
                            fontSize: PlaylistSizes.libraryTitle,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Playlist • ${widget.playlist.songs.length} songs',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: context.appTheme.subtext,
                              fontSize: PlaylistSizes.librarySubtitle),
                        ),
                      ],
                    ),
                  ),
                  if (widget.playlist.pinned)
                    Icon(Icons.push_pin,
                        color:
                            context.appTheme.iconColor(context.appTheme.button),
                        size: 16),
                  IconButton(
                    tooltip: 'Playlist options',
                    icon: Icon(Icons.more_horiz,
                        color: context.appTheme.subtext, size: 22),
                    onPressed: () {
                      final box = context.findRenderObject() as RenderBox;
                      _showMenu(context, box.localToGlobal(Offset.zero));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context, Offset position) {
    final currentUid = ref.read(authServiceProvider).currentUser?.uid;
    final isOwner = widget.playlist.sharedId == null ||
        widget.playlist.ownerUid == currentUid;
    showMenu<_PlaylistAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: context.appTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.appTheme.dividerColor),
      ),
      items: [
        _menuItem(
          _PlaylistAction.open,
          Icons.open_in_new,
          'Open',
        ),
        _menuItem(
          _PlaylistAction.addToQueue,
          Icons.queue_music_outlined,
          'Add to Queue',
        ),
        _menuItem(
          _PlaylistAction.addToPlaylist,
          Icons.playlist_add,
          'Add to another playlist',
        ),
        _menuItem(
          _PlaylistAction.pin,
          widget.playlist.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          widget.playlist.pinned ? 'Unpin playlist' : 'Pin playlist',
        ),
        _menuItem(
          _PlaylistAction.folder,
          Icons.create_new_folder_outlined,
          'Add to folder',
        ),
        if (widget.playlist.folderId != null)
          _menuItem(
            _PlaylistAction.removeFromFolder,
            Icons.folder_off_outlined,
            'Remove from folder',
          ),
        if (isOwner && !ref.read(guestSessionProvider))
          _menuItem(
            widget.playlist.sharedId == null
                ? _PlaylistAction.collaborate
                : _PlaylistAction.invite,
            Icons.group_add_outlined,
            widget.playlist.sharedId == null
                ? 'Make collaborative'
                : 'Invite collaborator',
          ),
        const PopupMenuDivider(height: 1),
        if (isOwner)
          _menuItem(
            _PlaylistAction.rename,
            Icons.edit_outlined,
            'Edit playlist',
          ),
        if (isOwner)
          _menuItem(
            _PlaylistAction.visibility,
            Icons.lock_outline,
            'Change privacy',
          ),
        _menuItem(
          _PlaylistAction.delete,
          Icons.delete_outline,
          isOwner ? 'Remove playlist' : 'Quit playlist',
          color: isOwner
              ? context.appTheme.notificationError
              : context.appTheme.text,
        ),
      ],
    ).then((action) {
      if (action == null) return;
      switch (action) {
        case _PlaylistAction.open:
          widget.onOpen();
        case _PlaylistAction.addToQueue:
          _addAllToQueue();
        case _PlaylistAction.addToPlaylist:
          _showAddToPlaylistDialog();
        case _PlaylistAction.pin:
          _togglePin();
        case _PlaylistAction.folder:
          _showFolderDialog();
        case _PlaylistAction.removeFromFolder:
          _removeFromFolder();
        case _PlaylistAction.collaborate:
          _makeCollaborative();
        case _PlaylistAction.invite:
          _showInviteDialog();
        case _PlaylistAction.rename:
          _showRenameDialog();
        case _PlaylistAction.visibility:
          _showVisibilityMenu();
        case _PlaylistAction.delete:
          if (isOwner) {
            _confirmDelete();
          } else {
            _quitPlaylist();
          }
      }
    });
  }

  PopupMenuItem<_PlaylistAction> _menuItem(
    _PlaylistAction value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final c = color ?? context.appTheme.text;
    return PopupMenuItem(
      value: value,
      height: 38,
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.withValues(alpha: 0.85)),
          SizedBox(width: 10),
          Text(label, style: TextStyle(color: c, fontSize: 13)),
        ],
      ),
    );
  }

  void _addAllToQueue() {
    final notifier = ref.read(playerProvider.notifier);
    for (final song in widget.playlist.songs) {
      notifier.addToQueue(song);
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      // Colours come from ThemeData.snackBarTheme. This one used to override
      // the background only, so its text fell back to onInverseSurface ==
      // `main` — near-black on near-black in Verdant Night.
      SnackBar(
        content: Text('${widget.playlist.songs.length} songs added to queue'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: widget.playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Rename Playlist',
            style: TextStyle(color: context.appTheme.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: context.appTheme.text),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: context.appTheme.subtext),
            filled: true,
            fillColor: context.appTheme.card,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: context.appTheme.subtext)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: context.appTheme.isVerdantNightDesktop
                    ? context.appTheme.text
                    : context.appTheme.button,
                foregroundColor: context.appTheme.isVerdantNightDesktop
                    ? context.appTheme.main
                    : context.appTheme.text),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            // The child's TextStyle would beat foregroundColor — that painted a
            // lime 'Save' on the lime fill in Verdant Night.
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && mounted) {
      await ref
          .read(libraryProvider.notifier)
          .renamePlaylistObj(widget.playlist, name);
    }
  }

  Future<void> _showAddToPlaylistDialog() async {
    final targets = ref
        .read(libraryProvider)
        .playlists
        .where((p) => !_same(p, widget.playlist))
        .toList();
    if (targets.isEmpty) {
      _showMessage('Create another playlist first.');
      return;
    }
    final target = await showDialog<Playlist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Add playlist to…',
            style: TextStyle(color: context.appTheme.text)),
        children: targets
            .map((p) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, p),
                  child: Text(p.name,
                      style: TextStyle(color: context.appTheme.text)),
                ))
            .toList(),
      ),
    );
    if (target == null || !mounted) return;
    await ref
        .read(libraryProvider.notifier)
        .copyPlaylistTo(widget.playlist, target);
    _showMessage(
        'Added ${widget.playlist.songs.length} songs to ${target.name}.');
  }

  Future<void> _togglePin() async {
    await ref.read(libraryProvider.notifier).organizePlaylist(
          widget.playlist,
          pinned: !widget.playlist.pinned,
        );
  }

  Future<void> _removeFromFolder() async {
    await ref.read(libraryProvider.notifier).organizePlaylist(
          widget.playlist,
          folderId: null,
          changeFolder: true,
        );
  }

  Future<void> _showFolderDialog() async {
    final folders = ref.read(libraryProvider).folders;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Add to folder',
            style: TextStyle(color: context.appTheme.text)),
        children: [
          ...folders.map((folder) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, folder),
                child: Text(folder,
                    style: TextStyle(color: context.appTheme.text)),
              )),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__new__'),
            child: Text('New folder…',
                style: TextStyle(
                    color: context.appTheme.isVerdantNightDesktop
                        ? context.appTheme.text
                        : context.appTheme.button)),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '__new__') {
      final controller = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.appTheme.card,
          title: Text('New folder',
              style: TextStyle(color: context.appTheme.text)),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (name == null || name.isEmpty) return;
      try {
        await ref.read(libraryProvider.notifier).createFolder(name);
        _showMessage('Folder created.');
      } catch (error) {
        _showMessage('Could not create folder: $error');
      }
      return;
    }
    await ref.read(libraryProvider.notifier).organizePlaylist(widget.playlist,
        folderId: selected, changeFolder: true);
  }

  Future<void> _makeCollaborative() async {
    try {
      final sharedId = await ref
          .read(libraryProvider.notifier)
          .makePlaylistCollaborative(widget.playlist);
      if (sharedId != null) {
        _showMessage(
            'Playlist is now collaborative. Use "Invite collaborator" to add friends.');
      } else {
        _showMessage('This playlist is already collaborative.');
      }
    } catch (error) {
      _showMessage('Could not enable collaboration: $error');
    }
  }

  Future<void> _showInviteDialog() async {
    final uid = await showCollaboratorInviteDialog(
      context,
      ref,
      widget.playlist,
    );
    if (uid == null || !mounted) return;
    try {
      await ref
          .read(libraryProvider.notifier)
          .inviteCollaborator(widget.playlist, uid);
      _showMessage('Playlist invitation sent.');
    } catch (error) {
      _showMessage(error.toString());
    }
  }

  bool _same(Playlist a, Playlist b) {
    if (a.sharedId != null || b.sharedId != null)
      return a.sharedId == b.sharedId;
    if (a.firestoreId != null && b.firestoreId != null) {
      return a.firestoreId == b.firestoreId;
    }
    return a.key != null && a.key == b.key;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showVisibilityMenu() async {
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Playlist privacy'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in ['private', 'friends', 'public'])
              RadioListTile<String>(
                value: option,
                groupValue: widget.playlist.visibility,
                title: Text(option[0].toUpperCase() + option.substring(1)),
                onChanged: (selected) => Navigator.pop(dialogContext, selected),
              ),
          ],
        ),
      ),
    );
    if (value != null && mounted) {
      await ref
          .read(libraryProvider.notifier)
          .setPlaylistVisibility(widget.playlist, value);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.appTheme.card,
        title: Text('Remove Playlist',
            style: TextStyle(color: context.appTheme.text)),
        content: Text(
          'Remove "${widget.playlist.name}"? This cannot be undone.',
          style: TextStyle(color: context.appTheme.subtext),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: context.appTheme.subtext)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: context.appTheme.notificationError,
                foregroundColor: context.appTheme.onErrorFill),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(libraryProvider.notifier)
          .deletePlaylistObj(widget.playlist);
    }
  }

  Future<void> _quitPlaylist() async {
    try {
      await ref
          .read(libraryProvider.notifier)
          .quitCollaborativePlaylist(widget.playlist);
      _showMessage('You left the playlist.');
    } catch (error) {
      _showMessage('Could not leave playlist: $error');
    }
  }
}

enum _PlaylistAction {
  open,
  addToQueue,
  addToPlaylist,
  pin,
  folder,
  removeFromFolder,
  collaborate,
  invite,
  rename,
  visibility,
  delete
}

// ─── Liked Songs tile (read-only, opens like a playlist) ─────────────────────

class _LikedSongsTile extends StatefulWidget {
  final Playlist playlist;
  final bool isActive;
  final VoidCallback onTap;

  const _LikedSongsTile({
    required this.playlist,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_LikedSongsTile> createState() => _LikedSongsTileState();
}

class _LikedSongsTileState extends State<_LikedSongsTile> {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.isActive
          ? context.appTheme.selectedRow
          : context.appTheme.main.withValues(alpha: 0),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              // Purple gradient icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.appTheme.misc.withValues(alpha: 0.65),
                      context.appTheme.misc,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.favorite,
                    color: context.appTheme.text, size: 22),
              ),
              SizedBox(width: 12),

              // Title + count
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Liked Songs',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.isActive &&
                                !context.appTheme.isVerdantNightDesktop
                            ? context.appTheme.button
                            : context.appTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Playlist • ${widget.playlist.songs.length} songs',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: context.appTheme.subtext, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
