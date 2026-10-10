// ============================================================
// services/download_index_service.dart
//
// Manages the rich Hive download index ('download_index' box).
//
// Responsibilities
// ─────────────────────────────────────────────────────────────
// 1. CRUD on DownloadIndexEntry objects.
// 2. Startup tasks (called once at boot, all non-blocking):
//    a) Clean up leftover .part files in Documents/Utify on desktop.
//    b) Verify every indexed entry still exists on disk/MediaStore;
//       remove dead entries.
//    c) Migrate old 'downloaded_songs' Hive entries (path-only map)
//       to DownloadIndexEntry objects.
//    d) Scan the desktop download folder for files with "[videoId]" in their name
//       that are NOT yet indexed, and re-import them (reinstall
//       recovery).
//
// Platform notes
// ─────────────────────────────────────────────────────────────
// • On Android API 29+ the audio path is a content:// URI.
//   Existence is checked via the MediaStore MethodChannel.
// • On Windows and Android API 28- the path is an absolute file path.
// • Thumbnails are always absolute file paths.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/download_index.dart';
import '../platform/download_storage.dart';

const String kDownloadIndexBox = 'download_index';
const String _kLegacyBox = 'downloaded_songs';

/// Exposed so main.dart can open the legacy box before migration.
const String kLegacyDownloadBox = 'downloaded_songs';

// ── Regex: "[<videoId>]" somewhere in the filename ──────────────────────────
final _videoIdInName = RegExp(r'\[([A-Za-z0-9_-]{11})\]');

class DownloadIndexService {
  DownloadIndexService._();
  static final DownloadIndexService instance = DownloadIndexService._();

  // ── Box access ─────────────────────────────────────────────────────────────

  Box<DownloadIndexEntry>? get _box {
    if (!Hive.isBoxOpen(kDownloadIndexBox)) return null;
    return Hive.box<DownloadIndexEntry>(kDownloadIndexBox);
  }

  // ── Read API ───────────────────────────────────────────────────────────────

  DownloadIndexEntry? get(String videoId) => _box?.get(videoId);

  bool isDownloaded(String videoId) => _box?.containsKey(videoId) ?? false;

  List<DownloadIndexEntry> getAll() => _box?.values.toList() ?? const [];

  int get totalSizeBytes =>
      _box?.values.fold<int>(0, (sum, e) => sum + e.sizeBytes) ?? 0;

  // ── Write API ──────────────────────────────────────────────────────────────

  Future<void> put(DownloadIndexEntry entry) async {
    try {
      await _box?.put(entry.videoId, entry);
    } catch (e) {
      debugPrint('[DownloadIndex] put failed for ${entry.videoId}: $e');
    }
  }

  Future<void> remove(String videoId) async {
    try {
      await _box?.delete(videoId);
    } catch (e) {
      debugPrint('[DownloadIndex] remove failed for $videoId: $e');
    }
  }

  Future<void> addPlaylistId(String videoId, String playlistId) async {
    final entry = get(videoId);
    if (entry == null) return;
    if (!entry.playlistIds.contains(playlistId)) {
      entry.playlistIds = [...entry.playlistIds, playlistId];
      await put(entry);
    }
  }

  Future<void> removePlaylistId(String videoId, String playlistId) async {
    final entry = get(videoId);
    if (entry == null) return;
    entry.playlistIds =
        entry.playlistIds.where((id) => id != playlistId).toList();
    await put(entry);
  }

  // ── Startup tasks ──────────────────────────────────────────────────────────

  /// Run all startup maintenance tasks. Safe to call before the UI is ready
  /// because everything is async and errors are swallowed.
  Future<void> runStartupMaintenance() async {
    try {
      await _cleanPartFiles();
    } catch (e) {
      debugPrint('[DownloadIndex] cleanPartFiles error: $e');
    }
    try {
      await _migrate();
    } catch (e) {
      debugPrint('[DownloadIndex] migrate error: $e');
    }
    try {
      await _verifyEntries();
    } catch (e) {
      debugPrint('[DownloadIndex] verifyEntries error: $e');
    }
    try {
      await _scanForUnindexed();
    } catch (e) {
      debugPrint('[DownloadIndex] scanForUnindexed error: $e');
    }
  }

  // ── (a) Clean up .part files ───────────────────────────────────────────────

  Future<void> _cleanPartFiles() async {
    try {
      final dir = await _musicUtifyDir();
      if (dir == null || !await dir.exists()) return;
      int count = 0;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.part')) {
          await entity.delete().catchError((_) => entity);
          count++;
        }
      }
      if (count > 0 && kDebugMode) {
        debugPrint('[DownloadIndex] cleaned $count .part file(s)');
      }
    } catch (e) {
      debugPrint('[DownloadIndex] _cleanPartFiles error: $e');
    }
  }

  // ── (b) Verify existing entries ────────────────────────────────────────────

  Future<void> _verifyEntries() async {
    final box = _box;
    if (box == null) return;
    final dead = <String>[];
    for (final entry in box.values) {
      final alive = await _pathExists(entry.path);
      if (!alive) dead.add(entry.videoId);
    }
    if (dead.isNotEmpty) {
      await box.deleteAll(dead);
      if (kDebugMode) {
        debugPrint('[DownloadIndex] pruned ${dead.length} dead entr(ies)');
      }
    }
  }

  // ── (c) Migrate old 'downloaded_songs' entries ────────────────────────────
  //
  // The legacy box was written as an untyped Box — it may contain values of
  // any Hive-supported type (String paths, bool flags, ints, etc.).  Opening
  // it as Box<String> causes Hive to cast every read to String?, which throws
  // "type 'bool' is not a subtype of type 'String?'" for non-String entries.
  //
  // We therefore access the raw Box (dynamic values) and filter down to
  // String entries that point to an existing file.  Each entry is wrapped in
  // its own try/catch so one bad entry can never abort the whole migration.

  Future<void> _migrate() async {
    if (!Hive.isBoxOpen(_kLegacyBox)) return;
    // Access as untyped Box so Hive never attempts a cast on read.
    final Box<dynamic> legacy = Hive.box<dynamic>(_kLegacyBox);
    if (legacy.isEmpty) return;

    final box = _box;
    if (box == null) return;

    var migrated = 0;
    var skipped = 0;

    for (final rawKey in legacy.keys.toList()) {
      final key = rawKey?.toString() ?? '';
      dynamic rawValue;
      try {
        rawValue = legacy.get(rawKey);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[DownloadIndex] migrate: cannot read key "$key" — $e');
        }
        skipped++;
        continue;
      }

      if (kDebugMode) {
        debugPrint('[DownloadIndex] migrate key="$key" '
            'runtimeType=${rawValue.runtimeType} '
            'value=${rawValue is String ? (rawValue.length > 80 ? "${rawValue.substring(0, 80)}…" : rawValue) : rawValue}');
      }

      // Per-entry isolation: any cast/file error must not abort the loop.
      try {
        // Only migrate String values that look like file paths.
        if (rawValue is! String) {
          skipped++;
          continue;
        }
        final path = rawValue;
        if (path.isEmpty) {
          skipped++;
          continue;
        }

        // Skip if already in the new index.
        if (box.containsKey(key)) continue;

        // Skip if the file no longer exists on disk (nothing to migrate).
        if (!await File(path).exists()) {
          if (kDebugMode) {
            debugPrint(
                '[DownloadIndex] migrate: skip "$key" — file not found: $path');
          }
          skipped++;
          continue;
        }

        // Try to derive videoId from the filename "[videoId]" pattern.
        final match = _videoIdInName.firstMatch(path);
        final videoId = match?.group(1) ?? key;

        // Determine format from extension.
        final ext = path.split('.').last.toLowerCase();
        final format =
            const {'m4a', 'webm', 'mp4', 'mp3'}.contains(ext) ? ext : 'mp4';

        int sizeBytes = 0;
        try {
          sizeBytes = await File(path).length();
        } catch (_) {}

        final entry = DownloadIndexEntry(
          videoId: videoId,
          path: path,
          format: format,
          sizeBytes: sizeBytes,
          downloadedAt: DateTime.now(),
        );
        await box.put(videoId, entry);
        migrated++;
      } catch (e, st) {
        // One bad entry must never kill the migration loop.
        debugPrint('[DownloadIndex] migrate: error for key "$key": $e\n$st');
        skipped++;
      }
    }

    if (kDebugMode) {
      debugPrint('[DownloadIndex] migration complete: '
          '$migrated migrated, $skipped skipped');
    }
  }

  // ── (d) Scan for unindexed files (reinstall recovery) ─────────────────────

  Future<void> _scanForUnindexed() async {
    final box = _box;
    if (box == null) return;

    final dir = await _musicUtifyDir();
    if (dir == null || !await dir.exists()) return;

    var imported = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final filename = entity.uri.pathSegments.last;
      // Skip temp files.
      if (filename.endsWith('.part') || filename.endsWith('.jpg')) continue;

      final match = _videoIdInName.firstMatch(filename);
      if (match == null) continue; // not a Utify-format file
      final videoId = match.group(1)!;

      // Already indexed — skip.
      if (box.containsKey(videoId)) continue;

      // Re-import it.
      final ext = filename.split('.').last.toLowerCase();
      final format =
          const {'m4a', 'webm', 'mp4', 'mp3'}.contains(ext) ? ext : 'mp4';
      int sizeBytes = 0;
      try {
        sizeBytes = await entity.length();
      } catch (_) {}

      // Try to parse "{Artist} - {Title} [{videoId}].{ext}".
      String artist = '';
      String title = '';
      final noExt = filename.substring(0, filename.lastIndexOf('.'));
      final noId =
          noExt.replaceAll(RegExp(r'\s*\[[A-Za-z0-9_-]{11}\]\s*$'), '');
      final dash = noId.indexOf(' - ');
      if (dash > 0) {
        artist = noId.substring(0, dash).trim();
        title = noId.substring(dash + 3).trim();
      } else {
        title = noId.trim();
      }

      final entry = DownloadIndexEntry(
        videoId: videoId,
        path: entity.path,
        format: format,
        sizeBytes: sizeBytes,
        title: title,
        artist: artist,
        downloadedAt: DateTime.now(),
      );
      await box.put(videoId, entry);
      imported++;
    }

    if (imported > 0 && kDebugMode) {
      debugPrint(
          '[DownloadIndex] re-imported $imported file(s) from desktop downloads');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<bool> _pathExists(String path) async {
    if (path.startsWith('content://')) {
      // Android MediaStore URI — ask the Kotlin side.
      return mediaStoreUriExists(path);
    }
    try {
      return File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns the desktop Documents/Utify directory if it can be determined without
  /// triggering a permission prompt.  Returns null if unavailable.
  Future<Directory?> _musicUtifyDir() async {
    try {
      if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          return Directory('$userProfile\\Documents\\Utify');
        }
        final docs = await getApplicationDocumentsDirectory();
        return Directory('${docs.path}\\Utify');
      }
      if (Platform.isAndroid) {
        // Use the same traversal as DownloadStorage.
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          Directory root = ext;
          for (int i = 0; i < 4; i++) {
            final parent = root.parent;
            if (parent.path == root.path) break;
            root = parent;
          }
          return Directory('${root.path}/Music/Utify');
        }
        return Directory('/storage/emulated/0/Music/Utify');
      }
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/Music/Utify');
    } catch (_) {
      return null;
    }
  }
}
