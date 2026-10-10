// ============================================================
// providers/library_provider.dart
// ============================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../models/playlist.dart';
import '../services/library_service.dart';
import '../services/firestore_service.dart';
import 'sync_provider.dart';

// ─── Library state ────────────────────────────────────────────────────────────

class LibraryState {
  final List<Song> likedSongs;
  final List<Song> recentlyPlayed;
  final List<Playlist> playlists;
  final List<String> folders;
  final bool isLoading;

  const LibraryState({
    this.likedSongs = const [],
    this.recentlyPlayed = const [],
    this.playlists = const [],
    this.folders = const [],
    this.isLoading = false,
  });

  LibraryState copyWith({
    List<Song>? likedSongs,
    List<Song>? recentlyPlayed,
    List<Playlist>? playlists,
    List<String>? folders,
    bool? isLoading,
  }) {
    return LibraryState(
      likedSongs: likedSongs ?? this.likedSongs,
      recentlyPlayed: recentlyPlayed ?? this.recentlyPlayed,
      playlists: playlists ?? this.playlists,
      folders: folders ?? this.folders,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  bool isLiked(String songId) => likedSongs.any((s) => s.id == songId);
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

class LibraryNotifier extends StateNotifier<LibraryState> {
  final LibraryService _hive;
  final FirestoreService _fs;

  String? _uid;
  StreamSubscription? _playlistsSub;
  StreamSubscription? _sharedPlaylistsSub;
  StreamSubscription? _foldersSub;
  StreamSubscription? _likesSub;
  List<Playlist> _ownedPlaylists = const [];
  List<Playlist> _sharedPlaylists = const [];

  LibraryNotifier(this._hive, this._fs) : super(const LibraryState()) {
    _loadLocal();
  }

  void _loadLocal() {
    state = LibraryState(
      likedSongs: _hive.getLikedSongs(),
      recentlyPlayed: _hive.getRecentlyPlayed(),
      playlists: _hive.getPlaylists(),
      folders: _hive.getFolders(),
    );
  }

  // ── Auth ───────────────────────────────────────────────────────────────────

  void initForUser(String uid) {
    if (_uid == uid) return;
    LibraryService.setGuestMode(false);
    _uid = uid;
    // Do not keep the unauthenticated Hive cache visible while the account
    // streams are loading. Those local-only objects can be stale ghosts from
    // an earlier offline creation and must not appear beside account data.
    state = state.copyWith(playlists: const [], isLoading: true);

    _playlistsSub?.cancel();
    _sharedPlaylistsSub?.cancel();
    _foldersSub?.cancel();
    _likesSub?.cancel();

    _playlistsSub = _fs.playlistsStream(uid).listen(
      (playlists) {
        _ownedPlaylists = playlists;
        state = state.copyWith(playlists: _mergePlaylists(), isLoading: false);
      },
      onError: (_) => state = state.copyWith(isLoading: false),
    );
    _sharedPlaylistsSub = _fs.sharedPlaylistsStream(uid).listen((shared) {
      _sharedPlaylists = shared;
      state = state.copyWith(playlists: _mergePlaylists());
    });
    _foldersSub = _fs.foldersStream(uid).listen(
          (folders) => state = state.copyWith(folders: folders),
          onError: (_) {},
        );

    _likesSub = _fs.likesStream(uid).listen((liked) {
      state = state.copyWith(likedSongs: liked);
      _syncLikesToHive(liked);
    });
    _fs.ensurePlaylistVisibilityDefaults(uid).catchError((_) {});
  }

  void initForGuest() {
    if (_uid == null) {
      LibraryService.setGuestMode(true);
      _loadLocal();
      return;
    }
    _playlistsSub?.cancel();
    _sharedPlaylistsSub?.cancel();
    _foldersSub?.cancel();
    _likesSub?.cancel();
    _uid = null;
    _ownedPlaylists = const [];
    _sharedPlaylists = const [];
    LibraryService.setGuestMode(true);
    _loadLocal();
  }

  List<Playlist> _mergePlaylists() {
    final merged = <Playlist>[];
    final seenShared = <String>{};
    final seenFirestore = <String>{};
    for (final playlist in [..._ownedPlaylists, ..._sharedPlaylists]) {
      if (playlist.sharedId != null && !seenShared.add(playlist.sharedId!)) {
        continue;
      }
      final firestoreId = playlist.firestoreId;
      if (firestoreId != null &&
          playlist.sharedId == null &&
          !seenFirestore.add(firestoreId)) {
        continue;
      }
      merged.add(playlist);
    }
    return merged;
  }

  void resetForLogout() {
    _playlistsSub?.cancel();
    _likesSub?.cancel();
    _sharedPlaylistsSub?.cancel();
    _foldersSub?.cancel();
    _ownedPlaylists = const [];
    _sharedPlaylists = const [];
    _uid = null;
    LibraryService.setGuestMode(false);
    _loadLocal();
  }

  Future<void> _syncLikesToHive(List<Song> liked) async {
    try {
      final box = _hive.likedBox;
      final currentKeys = box.keys.map((k) => k.toString()).toSet();
      final newKeys = liked.map((s) => s.id).toSet();
      if (currentKeys.length == newKeys.length && currentKeys.containsAll(newKeys)) {
        return;
      }
      await box.clear();
      if (liked.isNotEmpty) {
        await box.putAll({for (final s in liked) s.id: s});
      }
    } catch (_) {}
  }

  // ── Likes ──────────────────────────────────────────────────────────────────

  Future<void> toggleLike(Song song) async {
    final wasLiked = state.isLiked(song.id);

    // Optimistic update
    state = state.copyWith(
      likedSongs: wasLiked
          ? state.likedSongs.where((s) => s.id != song.id).toList()
          : [song, ...state.likedSongs],
    );

    await _hive.toggleLike(song).catchError((_) {});

    if (_uid != null) {
      if (wasLiked) {
        await _fs.unlikeSong(_uid!, song.id).catchError((_) {});
      } else {
        await _fs.likeSong(_uid!, song).catchError((_) {});
      }
    }
  }

  // ── Recently played ────────────────────────────────────────────────────────

  Future<void> addToRecentlyPlayed(Song song) async {
    await _hive.addToRecentlyPlayed(song);
    state = state.copyWith(recentlyPlayed: _hive.getRecentlyPlayed());
  }

  // ── Playlists ──────────────────────────────────────────────────────────────

  Future<void> createPlaylist(String name,
      {String? description,
      String visibility = 'private',
      bool collaborative = false}) async {
    if (_uid != null) {
      if (collaborative) {
        await _fs.createSharedPlaylist(_uid!, name, const [],
            visibility: visibility);
      } else {
        await _fs.createPlaylist(_uid!, name,
            description: description, visibility: visibility);
        // The live Firestore listener updates the library.
      }
    } else {
      await _hive.createPlaylist(name,
          description: description, visibility: visibility);
      state = state.copyWith(playlists: _hive.getPlaylists());
    }
  }

  Future<void> createPlaylistWithSongs(String name, List<Song> songs) async {
    if (_uid != null) {
      await _fs.createPlaylistWithSongs(_uid!, name, songs);
      return;
    }

    await _hive.createPlaylist(name);
    final playlist = _hive.getPlaylists().last;
    final key = playlist.key as int;
    for (final song in songs) {
      await _hive.addSongToPlaylist(key, song);
    }
    state = state.copyWith(playlists: _hive.getPlaylists());
  }

  Future<void> copyPlaylistTo(Playlist source, Playlist target) async {
    if (_uid == null || source.songs.isEmpty) return;
    if (target.sharedId != null) {
      await _fs.addSongsToSharedPlaylist(target.sharedId!, source.songs);
    } else if (target.firestoreId != null) {
      await _fs.addSongsToPlaylist(_uid!, target.firestoreId!, source.songs);
    } else {
      final targetKey = target.key as int?;
      if (targetKey != null) {
        for (final song in source.songs) {
          await _hive.addSongToPlaylist(targetKey, song);
        }
      }
    }
  }

  Future<void> createCollaborativePlaylist(
      String name, List<Song> songs) async {
    if (_uid == null) return;
    await _fs.createSharedPlaylist(_uid!, name, songs);
  }

  Future<String?> makePlaylistCollaborative(Playlist playlist) async {
    if (_uid == null || playlist.sharedId != null) return playlist.sharedId;
    final sharedId =
        await _fs.createSharedPlaylist(_uid!, playlist.name, playlist.songs);
    final playlistId = playlist.firestoreId;
    if (playlistId != null) {
      await _fs.deletePlaylist(_uid!, playlistId);
    }
    final shared = Playlist(
      name: playlist.name,
      songs: playlist.songs,
      createdAt: playlist.createdAt,
      description: playlist.description,
      visibility: playlist.visibility,
      pinned: playlist.pinned,
      folderId: playlist.folderId,
      sharedId: sharedId,
      ownerUid: _uid,
    );
    // Attach the Firestore ID expando so the new shared playlist is identifiable.
    playlistFirestoreIds[shared] = sharedId;
    state = state.copyWith(
      playlists: state.playlists
          .map((p) => _matchesPlaylist(p, playlist) ? shared : p)
          .toList(),
    );
    return sharedId;
  }

  Future<void> inviteCollaborator(Playlist playlist, String uid) async {
    if (_uid == null || playlist.sharedId == null) return;
    await _fs.inviteToSharedPlaylist(
      sharedPlaylistId: playlist.sharedId!,
      fromUid: _uid!,
      toUid: uid,
      playlistName: playlist.name,
    );
  }

  Future<void> quitCollaborativePlaylist(Playlist playlist) async {
    if (_uid == null || playlist.sharedId == null) return;
    await _fs.removeCollaborator(playlist.sharedId!, _uid!);
    state = state.copyWith(
      playlists: state.playlists
          .where((item) => item.sharedId != playlist.sharedId)
          .toList(),
    );
  }

  Future<void> createFolder(String name) async {
    if (name.trim().isEmpty) return;
    if (_uid == null) {
      await _hive.addFolder(name.trim());
      state = state.copyWith(folders: _hive.getFolders());
      return;
    }
    await _fs.createFolder(_uid!, name.trim());
  }

  Future<void> renameFolder(String oldName, String newName) async {
    final next = newName.trim();
    if (next.isEmpty || oldName == next) return;
    if (_uid == null) {
      await _hive.renameFolder(oldName, next);
      state = state.copyWith(folders: _hive.getFolders());
      for (final playlist
          in state.playlists.where((p) => p.folderId == oldName)) {
        await organizePlaylist(playlist, folderId: next, changeFolder: true);
      }
      return;
    }
    await _fs.renameFolder(_uid!, oldName, next);
    for (final playlist
        in state.playlists.where((p) => p.folderId == oldName)) {
      await organizePlaylist(playlist, folderId: next, changeFolder: true);
    }
  }

  Future<void> deleteFolder(String name) async {
    if (_uid == null) {
      await _hive.deleteFolder(name);
      state = state.copyWith(folders: _hive.getFolders());
      final affected =
          state.playlists.where((p) => p.folderId == name).toList();
      for (final playlist in affected) {
        await organizePlaylist(playlist, folderId: null, changeFolder: true);
      }
      return;
    }
    await _fs.deleteFolder(_uid!, name);
    final affected =
        state.playlists.where((playlist) => playlist.folderId == name).toList();
    for (final playlist in affected) {
      await organizePlaylist(playlist, folderId: null, changeFolder: true);
    }
  }

  Future<void> organizePlaylist(Playlist playlist,
      {bool? pinned, String? folderId, bool changeFolder = false}) async {
    final nextPinned = pinned ?? playlist.pinned;
    final nextFolder = changeFolder ? folderId : playlist.folderId;
    final updated = Playlist(
      name: playlist.name,
      songs: playlist.songs,
      createdAt: playlist.createdAt,
      description: playlist.description,
      visibility: playlist.visibility,
      pinned: nextPinned,
      folderId: nextFolder,
      sharedId: playlist.sharedId,
      ownerName: playlist.ownerName,
    );

    // Copy the Firestore ID expando onto the new object immediately.
    final fsId = playlist.firestoreId ?? playlist.sharedId;
    if (fsId != null) playlistFirestoreIds[updated] = fsId;

    // ── Optimistic UI update BEFORE the async call ────────────────────────
    // We scan state.playlists *now*, while we still hold the same object
    // references. Doing it after an await risks the Firestore snapshot
    // listener replacing the list with fresh objects that don't match.
    bool matched = false;
    final replaced = state.playlists.map((current) {
      if (matched) return current;
      final sameShared =
          playlist.sharedId != null && current.sharedId == playlist.sharedId;
      final sameFirestore = fsId != null && current.firestoreId == fsId;
      final sameHive = playlist.key != null && current.key == playlist.key;
      // Name+createdAt fallback ONLY for local-only playlists (no Firestore ID).
      final sameName = fsId == null &&
          current.firestoreId == null &&
          current.sharedId == null &&
          current.name == playlist.name &&
          current.createdAt == playlist.createdAt;
      if (sameShared || sameFirestore || sameHive || sameName) {
        matched = true;
        return updated;
      }
      return current;
    }).toList();

    if (matched) {
      state = state.copyWith(playlists: replaced);
    }

    // ── Persist to Firestore / Hive ───────────────────────────────────────
    if ((playlist.firestoreId != null || playlist.sharedId != null) &&
        _uid != null) {
      await _fs.setPlaylistOrganization(
        uid: _uid!,
        playlist: playlist,
        pinned: nextPinned,
        folderId: nextFolder,
      );
    } else {
      final key = playlist.key as int?;
      if (key != null) {
        try {
          final local = _hive.getPlaylists().firstWhere((p) => p.key == key);
          local.pinned = nextPinned;
          local.folderId = nextFolder;
          await local.save();
        } catch (_) {}
      }
    }
  }

  /// Rename a playlist by Playlist object (primary — works for both Hive and Firestore playlists).
  Future<void> renamePlaylistObj(Playlist playlist, String name) async {
    final fsId = playlist.firestoreId;
    final hiveKey = playlist.key as int?;

    // Optimistic UI
    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matchesPlaylist(p, playlist)) {
          return Playlist(
              name: name,
              songs: p.songs,
              createdAt: p.createdAt,
              description: p.description,
              visibility: p.visibility,
              pinned: p.pinned,
              folderId: p.folderId,
              sharedId: p.sharedId);
        }
        return p;
      }).toList(),
    );

    if (hiveKey != null) {
      await _hive.renamePlaylist(hiveKey, name).catchError((_) {});
    }
    if (_uid != null && fsId != null) {
      await _fs.renamePlaylist(_uid!, fsId, name).catchError((_) {});
    }
  }

  /// Rename a playlist. Pass the Playlist object — we extract the right ID.
  /// Legacy overload that accepts a hive key integer.
  Future<void> renamePlaylist(int hiveKey, String name,
      {String? firestoreId}) async {
    final fsId = firestoreId ?? _firestoreIdForHiveKey(hiveKey);

    // Optimistic UI
    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matches(p, hiveKey, fsId)) {
          return Playlist(
              name: name,
              songs: p.songs,
              createdAt: p.createdAt,
              description: p.description,
              visibility: p.visibility,
              pinned: p.pinned,
              folderId: p.folderId,
              sharedId: p.sharedId);
        }

        return p;
      }).toList(),
    );

    await _hive.renamePlaylist(hiveKey, name).catchError((_) {});
    if (_uid != null && fsId != null) {
      await _fs.renamePlaylist(_uid!, fsId, name).catchError((_) {});
    }
  }

  Future<void> setPlaylistVisibility(
      Playlist playlist, String visibility) async {
    if (!{'private', 'friends', 'public'}.contains(visibility)) return;
    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matchesPlaylist(p, playlist)) {
          return Playlist(
            name: p.name,
            songs: p.songs,
            createdAt: p.createdAt,
            description: p.description,
            visibility: visibility,
            pinned: p.pinned,
            folderId: p.folderId,
            sharedId: p.sharedId,
          );
        }
        return p;
      }).toList(),
    );

    final fsId = playlist.firestoreId;
    if (_uid != null && fsId != null) {
      await _fs.setPlaylistVisibility(
        _uid!,
        fsId,
        visibility,
        sharedPlaylistId: playlist.sharedId,
      );
    }
    final hiveKey = playlist.key as int?;
    if (hiveKey != null) {
      final local = _hive.getPlaylists().firstWhere(
            (p) => p.key == hiveKey,
            orElse: () => playlist,
          );
      local.visibility = visibility;
      await local.save();
    }
  }

  /// Delete a playlist by Playlist object (primary — works for both Hive and Firestore playlists).
  Future<void> deletePlaylistObj(Playlist playlist) async {
    final fsId = playlist.firestoreId;
    final hiveKey = playlist.key as int?;

    state = state.copyWith(
      playlists:
          state.playlists.where((p) => !_matchesPlaylist(p, playlist)).toList(),
    );

    if (hiveKey != null) {
      await _hive.deletePlaylist(hiveKey).catchError((_) {});
    }
    if (_uid != null && fsId != null && playlist.sharedId == null) {
      await _fs.deletePlaylist(_uid!, fsId).catchError((_) {});
    }
  }

  /// Delete a playlist. Accepts either hiveKey or Playlist object.
  /// Legacy overload that accepts a hive key integer.
  Future<void> deletePlaylist(int hiveKey, {String? firestoreId}) async {
    final fsId = firestoreId ?? _firestoreIdForHiveKey(hiveKey);

    state = state.copyWith(
      playlists:
          state.playlists.where((p) => !_matches(p, hiveKey, fsId)).toList(),
    );

    await _hive.deletePlaylist(hiveKey).catchError((_) {});
    if (_uid != null && fsId != null) {
      await _fs.deletePlaylist(_uid!, fsId).catchError((_) {});
    }
  }

  /// Add a song to a playlist — takes the Playlist object directly.
  /// This is the primary entry point used by AddToPlaylistSheet and
  /// SongContextMenu, so it doesn't need a hive key at all.
  Future<void> addSongToPlaylistObj(Playlist playlist, Song song) async {
    final fsId = playlist.firestoreId;
    final hiveKey = playlist.key as int?;

    // Optimistic UI
    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matchesPlaylist(p, playlist)) {
          if (!p.songs.any((s) => s.id == song.id)) {
            return Playlist(
                name: p.name,
                songs: [...p.songs, song],
                createdAt: p.createdAt,
                description: p.description,
                visibility: p.visibility,
                pinned: p.pinned,
                folderId: p.folderId,
                sharedId: p.sharedId);
          }
        }
        return p;
      }).toList(),
    );

    if (hiveKey != null) {
      await _hive.addSongToPlaylist(hiveKey, song).catchError((_) {});
    }
    if (_uid != null && playlist.sharedId != null) {
      await _fs.addSongsToSharedPlaylist(
          playlist.sharedId!, [song]).catchError((_) {});
    } else if (_uid != null && fsId != null) {
      await _fs.addSongToPlaylist(_uid!, fsId, song).catchError((_) {});
    }
  }

  /// Legacy overload used by some existing screens that pass hiveKey.
  Future<void> addSongToPlaylist(int playlistKey, Song song,
      {String? firestoreId}) async {
    final fsId = firestoreId ?? _firestoreIdForHiveKey(playlistKey);

    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matches(p, playlistKey, fsId)) {
          if (!p.songs.any((s) => s.id == song.id)) {
            return Playlist(
                name: p.name,
                songs: [...p.songs, song],
                createdAt: p.createdAt,
                description: p.description,
                visibility: p.visibility,
                pinned: p.pinned,
                folderId: p.folderId,
                sharedId: p.sharedId);
          }
        }
        return p;
      }).toList(),
    );

    await _hive.addSongToPlaylist(playlistKey, song).catchError((_) {});
    if (_uid != null && fsId != null) {
      await _fs.addSongToPlaylist(_uid!, fsId, song).catchError((_) {});
    }
  }

  /// Reorder the songs inside a playlist (drag handle in the playlist view).
  ///
  /// State is updated first so the list settles immediately, then persisted to
  /// Hive and Firestore. A failure on the remote write is swallowed, matching
  /// the other playlist mutations.
  Future<void> reorderPlaylistSongs(
    Playlist playlist,
    int oldIndex,
    int newIndex,
  ) async {
    final current = state.playlists.where((p) => _matchesPlaylist(p, playlist));
    if (current.isEmpty) return;

    // ReorderableListView reports the drop index before the item is removed.
    if (newIndex > oldIndex) newIndex--;

    final reordered = List<Song>.from(current.first.songs);
    if (oldIndex < 0 || oldIndex >= reordered.length) return;
    if (newIndex < 0 || newIndex >= reordered.length) return;

    final song = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, song);

    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (!_matchesPlaylist(p, playlist)) return p;
        return Playlist(
            name: p.name,
            songs: reordered,
            createdAt: p.createdAt,
            description: p.description,
            visibility: p.visibility,
            pinned: p.pinned,
            folderId: p.folderId,
            sharedId: p.sharedId);
      }).toList(),
    );

    final hiveKey = playlist.key as int?;
    if (hiveKey != null) {
      await _hive.updatePlaylistSongs(hiveKey, reordered).catchError((_) {});
    }
    if (_uid != null && playlist.sharedId != null) {
      await _fs
          .updateSharedPlaylistSongsOrder(playlist.sharedId!, reordered)
          .catchError((_) {});
    } else if (_uid != null && playlist.firestoreId != null) {
      await _fs
          .updatePlaylistSongsOrder(_uid!, playlist.firestoreId!, reordered)
          .catchError((_) {});
    }
  }

  /// Remove a song from a playlist — takes the Playlist object directly.
  Future<void> removeSongFromPlaylistObj(
      Playlist playlist, String songId) async {
    final fsId = playlist.firestoreId;
    final hiveKey = playlist.key as int?;

    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matchesPlaylist(p, playlist)) {
          return Playlist(
              name: p.name,
              songs: p.songs.where((s) => s.id != songId).toList(),
              createdAt: p.createdAt,
              description: p.description,
              visibility: p.visibility,
              pinned: p.pinned,
              folderId: p.folderId,
              sharedId: p.sharedId);
        }
        return p;
      }).toList(),
    );

    if (hiveKey != null) {
      await _hive.removeSongFromPlaylist(hiveKey, songId).catchError((_) {});
    }
    if (_uid != null && playlist.sharedId != null) {
      await _fs
          .removeSongFromSharedPlaylist(playlist.sharedId!, songId)
          .catchError((_) {});
    } else if (_uid != null && fsId != null) {
      await _fs.removeSongFromPlaylist(_uid!, fsId, songId).catchError((_) {});
    }
  }

  /// Legacy overload.
  Future<void> removeSongFromPlaylist(int playlistKey, String songId,
      {String? firestoreId}) async {
    final fsId = firestoreId ?? _firestoreIdForHiveKey(playlistKey);

    state = state.copyWith(
      playlists: state.playlists.map((p) {
        if (_matches(p, playlistKey, fsId)) {
          return Playlist(
              name: p.name,
              songs: p.songs.where((s) => s.id != songId).toList(),
              createdAt: p.createdAt,
              description: p.description,
              visibility: p.visibility,
              pinned: p.pinned,
              folderId: p.folderId,
              sharedId: p.sharedId);
        }
        return p;
      }).toList(),
    );

    await _hive.removeSongFromPlaylist(playlistKey, songId).catchError((_) {});
    if (_uid != null && fsId != null) {
      await _fs.removeSongFromPlaylist(_uid!, fsId, songId).catchError((_) {});
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Get the Firestore ID for a playlist identified by its Hive key.
  String? _firestoreIdForHiveKey(int hiveKey) {
    try {
      return state.playlists.firstWhere((p) => p.key == hiveKey).firestoreId;
    } catch (_) {
      return null;
    }
  }

  bool _matches(Playlist p, int? hiveKey, String? fsId) {
    if (fsId != null && p.firestoreId == fsId) return true;
    if (hiveKey != null && p.key == hiveKey) return true;
    return false;
  }

  bool _matchesPlaylist(Playlist p, Playlist target) {
    if (target.sharedId != null && p.sharedId == target.sharedId) return true;
    if (target.firestoreId != null && p.firestoreId == target.firestoreId) {
      return true;
    }
    if (target.key != null && p.key == target.key) return true;
    // Last resort: same name + createdAt — only for local-only playlists.
    if (target.firestoreId == null &&
        target.sharedId == null &&
        p.firestoreId == null &&
        p.sharedId == null) {
      return p.name == target.name && p.createdAt == target.createdAt;
    }
    return false;
  }

  @override
  void dispose() {
    _playlistsSub?.cancel();
    _sharedPlaylistsSub?.cancel();
    _foldersSub?.cancel();
    _likesSub?.cancel();
    super.dispose();
  }
}

// ─── Providers ───────────────────────────────────────────────────────────────

final libraryServiceProvider =
    Provider<LibraryService>((ref) => LibraryService());

final libraryProvider =
    StateNotifierProvider<LibraryNotifier, LibraryState>((ref) {
  return LibraryNotifier(
    ref.watch(libraryServiceProvider),
    ref.watch(firestoreServiceProvider),
  );
});
