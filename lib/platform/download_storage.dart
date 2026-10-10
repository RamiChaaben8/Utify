// ============================================================
// platform/download_storage.dart
//
// Platform abstraction for user-initiated download storage.
//
// Windows: %USERPROFILE%\Music\Utify\
//   • Audio file + .jpg thumbnail saved in the same folder.
//
// Android API 29+ (Q+): MediaStore insertions for audio.
//   • Audio goes to the public Music/Utify collection via a
//     Kotlin MethodChannel (no broad storage permission needed).
//   • Thumbnails go to app-private storage so they never appear
//     in the Gallery.
//
// Android API 28 and below: direct file access to
//   /storage/emulated/0/Music/Utify/ (WRITE_EXTERNAL_STORAGE
//   permission requested by the app already).
//   Thumbnails still go to app-private storage.
//
// Callers receive a [DownloadStorageResult] with the audio path
// (or MediaStore URI string on API 29+) and thumbnail path.
//
// No Platform.isAndroid / Platform.isWindows checks live outside
// this file — they are all centralised here.
// ============================================================

import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// ── MediaStore channel (Android API 29+) ─────────────────────────────────────

const _kMediaStoreChannel = 'com.example.testf/mediastore';
final _mediaStoreChannel = MethodChannel(_kMediaStoreChannel);

// ── Public result ─────────────────────────────────────────────────────────────

class DownloadStorageResult {
  /// On Android API 29+, a content:// URI string.
  /// On all other platforms, an absolute file path.
  final String audioPath;

  /// Absolute path to the thumbnail file (always a local file).
  final String thumbnailPath;

  const DownloadStorageResult({
    required this.audioPath,
    required this.thumbnailPath,
  });
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Returns the directory where new downloads should be placed.
///
/// On Android this is the app-external path (used for API 28 direct writes
/// and for thumbnail storage on all API levels).
/// On Windows it is %USERPROFILE%\Music\Utify\.
Future<Directory> getDownloadDirectory() async {
  if (Platform.isWindows) {
    return _windowsDownloadDir();
  }
  if (Platform.isAndroid) {
    return _androidPrivateDownloadDir();
  }
  // Fallback for other platforms.
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/Music/Utify');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Sanitise a string so it is safe to use as a filename component.
/// Removes characters illegal on Windows and Android FAT32 volumes,
/// collapses whitespace, and trims to 200 characters max.
String sanitiseFilename(String input) {
  return input
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .substring(0, input.length > 200 ? 200 : input.length);
}

/// Builds the canonical filename (without extension) for a download.
/// Pattern: "{Artist} - {Title} [{videoId}]"
String buildDownloadBasename({
  required String artist,
  required String title,
  required String videoId,
}) {
  final safeArtist = sanitiseFilename(artist);
  final safeTitle = sanitiseFilename(title);
  return '$safeArtist - $safeTitle [$videoId]';
}

/// Saves an audio [bytes] buffer to the correct location for the platform
/// and returns a [DownloadStorageResult].
///
/// [basename] must already be sanitised (use [buildDownloadBasename]).
/// [extension] should be 'm4a' or 'webm' (without the dot).
///
/// On Android API 29+ the audio is inserted via MediaStore; the returned
/// [audioPath] is a `content://` URI string.
/// On all other paths the audio is written directly to a file and [audioPath]
/// is the absolute path.
Future<DownloadStorageResult> saveDownloadedAudio({
  required String basename,
  required String extension,
  required String videoId,
  required List<int> bytes,
}) async {
  if (Platform.isAndroid) {
    return _androidSaveAudio(
      basename: basename,
      extension: extension,
      videoId: videoId,
      bytes: bytes,
    );
  }

  // Windows (and other platforms).
  final dir = await _windowsDownloadDir();
  final audioFile = File('${dir.path}\\$basename.$extension');
  await audioFile.writeAsBytes(bytes, flush: true);
  // Thumbnail is also in the same Music/Utify folder on Windows.
  final thumbnailPath = '${dir.path}\\$basename.jpg';
  return DownloadStorageResult(
    audioPath: audioFile.path,
    thumbnailPath: thumbnailPath,
  );
}

/// Returns the path where the thumbnail for [basename] should be saved.
/// On Android this is always a private app-data path (never in Gallery).
/// On Windows it is next to the audio in Music/Utify.
Future<String> thumbnailPathFor({
  required String basename,
  required bool isAndroid,
}) async {
  if (isAndroid) {
    return _androidThumbnailPath(basename);
  }
  final dir = await _windowsDownloadDir();
  return '${dir.path}\\$basename.jpg';
}

// ── Windows helpers ───────────────────────────────────────────────────────────

Future<Directory> _windowsDownloadDir() async {
  final userProfile = Platform.environment['USERPROFILE'];
  final path = userProfile != null
      ? '$userProfile\\Music\\Utify'
      : '${(await getApplicationDocumentsDirectory()).path}\\Music\\Utify';
  final dir = Directory(path);
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

// ── Android helpers ───────────────────────────────────────────────────────────

/// App-private directory for thumbnails (never appears in Gallery).
Future<String> _androidThumbnailPath(String basename) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/download_thumbs');
  if (!await dir.exists()) await dir.create(recursive: true);
  return '${dir.path}/$basename.jpg';
}

/// App-external directory used for API 28 direct writes and for the
/// thumbnail base on all API levels.
Future<Directory> _androidPrivateDownloadDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      // Walk up from the app-private external folder to the storage root.
      Directory root = ext;
      for (int i = 0; i < 4; i++) {
        final parent = root.parent;
        if (parent.path == root.path) break;
        root = parent;
      }
      final dir = Directory('${root.path}/Music/Utify');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  } catch (_) {}
  // Fallback to a known writable path.
  const fallback = '/storage/emulated/0/Music/Utify';
  final dir = Directory(fallback);
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  } catch (_) {}
  final docs = await getApplicationDocumentsDirectory();
  final alt = Directory('${docs.path}/Music/Utify');
  if (!await alt.exists()) await alt.create(recursive: true);
  return alt;
}

/// Saves audio via MediaStore on API 29+ or direct file on API 28-.
Future<DownloadStorageResult> _androidSaveAudio({
  required String basename,
  required String extension,
  required String videoId,
  required List<int> bytes,
}) async {
  final thumbnailPath = await _androidThumbnailPath(basename);

  // Try MediaStore first (API 29+).
  try {
    final result = await _mediaStoreChannel.invokeMethod<String>(
      'insertAudio',
      {
        'basename': basename,
        'extension': extension,
        'bytes': bytes,
      },
    );
    if (result != null && result.isNotEmpty) {
      debugPrint('[DownloadStorage] MediaStore URI: $result');
      return DownloadStorageResult(
        audioPath: result,
        thumbnailPath: thumbnailPath,
      );
    }
  } on PlatformException catch (e) {
    debugPrint('[DownloadStorage] MediaStore failed (${e.code}): ${e.message}');
    // Fall through to direct file write.
  } catch (e) {
    debugPrint('[DownloadStorage] MediaStore unexpected error: $e');
    // Fall through to direct file write.
  }

  // Direct file write (API 28- or MediaStore failure fallback).
  final dir = await _androidPrivateDownloadDir();
  final audioFile = File('${dir.path}/$basename.$extension');
  await audioFile.writeAsBytes(bytes, flush: true);
  return DownloadStorageResult(
    audioPath: audioFile.path,
    thumbnailPath: thumbnailPath,
  );
}

/// On Android API 29+ we write audio via a Kotlin MethodChannel instead of
/// requesting WRITE_EXTERNAL_STORAGE.  This function opens a temporary file
/// at [tempPath] and asks the Kotlin side to move it into MediaStore.
///
/// Returns a `content://` URI string on success, or null on failure.
Future<String?> insertAudioViaMediaStore({
  required String basename,
  required String extension,
  required String tempFilePath,
}) async {
  try {
    final result = await _mediaStoreChannel.invokeMethod<String>(
      'insertAudioFromFile',
      {
        'basename': basename,
        'extension': extension,
        'tempPath': tempFilePath,
      },
    );
    return result;
  } on PlatformException catch (e) {
    debugPrint('[DownloadStorage] insertAudioFromFile failed: ${e.message}');
    return null;
  } catch (e) {
    debugPrint('[DownloadStorage] insertAudioFromFile error: $e');
    return null;
  }
}

/// Open a write stream to a MediaStore audio entry (Android API 29+).
/// Returns null if MediaStore is not available or the call fails.
///
/// Usage: obtain the URI, then write to it using [openMediaStoreOutputStream].
Future<String?> createMediaStoreAudioEntry({
  required String basename,
  required String extension,
}) async {
  try {
    final result = await _mediaStoreChannel.invokeMethod<String>(
      'createAudioEntry',
      {
        'basename': basename,
        'extension': extension,
      },
    );
    return result;
  } on PlatformException catch (e) {
    debugPrint('[DownloadStorage] createAudioEntry failed: ${e.message}');
    return null;
  } catch (_) {
    return null;
  }
}

/// Checks whether a MediaStore entry (content:// URI) still exists.
Future<bool> mediaStoreUriExists(String uri) async {
  if (!uri.startsWith('content://')) return false;
  try {
    final result = await _mediaStoreChannel.invokeMethod<bool>(
      'uriExists',
      {'uri': uri},
    );
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Copies a MediaStore-owned file into app-private storage for reliable
/// playback by audio backends that do not support content:// directly.
Future<bool> copyMediaStoreUriToFile({
  required String uri,
  required String targetPath,
}) async {
  if (!uri.startsWith('content://')) return false;
  try {
    final result = await _mediaStoreChannel.invokeMethod<bool>(
      'copyUriToFile',
      {'uri': uri, 'targetPath': targetPath},
    );
    return result ?? false;
  } on PlatformException catch (e) {
    debugPrint('[DownloadStorage] copyUriToFile failed: ${e.message}');
    return false;
  } catch (e) {
    debugPrint('[DownloadStorage] copyUriToFile error: $e');
    return false;
  }
}
