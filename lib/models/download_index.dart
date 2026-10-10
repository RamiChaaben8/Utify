// ============================================================
// models/download_index.dart
//
// Hive-persisted download index entry.
//
// Hive box: 'download_index'
// Key:       videoId (String)
// Value:     DownloadIndexEntry
//
// The `path` field stores:
//   • On Android API 29+: a content:// URI string from MediaStore.
//   • On all other platforms: an absolute file path.
//
// Migration: old entries from 'downloaded_songs' (path-only map)
// are imported in DownloadIndexService.migrate() with format='mp4'
// and zero bitrate/size (we don't have the old metadata).
// ============================================================

import 'package:hive/hive.dart';

part 'download_index.g.dart';

@HiveType(typeId: 3)
class DownloadIndexEntry extends HiveObject {
  /// videoId (stable YouTube ID).
  @HiveField(0)
  final String videoId;

  /// Absolute file path or content:// URI (Android API 29+).
  @HiveField(1)
  String path;

  /// Absolute path to the locally cached thumbnail .jpg, or empty string.
  @HiveField(2)
  String thumbnailPath;

  /// Audio container: 'm4a', 'webm', 'mp4' (legacy), etc.
  @HiveField(3)
  String format;

  /// Bitrate in bits/second. 0 for migrated legacy entries.
  @HiveField(4)
  int bitrate;

  /// File size in bytes. 0 for migrated legacy entries.
  @HiveField(5)
  int sizeBytes;

  /// Song title (duplicated here so we can show the index offline).
  @HiveField(6)
  String title;

  /// Artist / channel name.
  @HiveField(7)
  String artist;

  /// Duration in milliseconds.
  @HiveField(8)
  int durationMs;

  /// When the download completed.
  @HiveField(9)
  DateTime downloadedAt;

  /// Playlist IDs (Firestore or Hive key strings) that have auto-download on.
  @HiveField(10)
  List<String> playlistIds;

  /// Optional public MediaStore URI for the exported copy on Android.
  /// [path] remains the canonical app-private playback path.
  @HiveField(11)
  String? publicUri;

  DownloadIndexEntry({
    required this.videoId,
    required this.path,
    this.thumbnailPath = '',
    this.format = 'm4a',
    this.bitrate = 0,
    this.sizeBytes = 0,
    this.title = '',
    this.artist = '',
    this.durationMs = 0,
    DateTime? downloadedAt,
    List<String>? playlistIds,
    this.publicUri,
  })  : downloadedAt = downloadedAt ?? DateTime.now(),
        playlistIds = playlistIds ?? [];
}
