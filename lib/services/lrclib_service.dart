// ============================================================
// services/lrclib_service.dart
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';

import '../models/song.dart';
import '../services/youtube_service.dart' show LyricLine;

const String _kBase = 'https://lrclib.net/api';
const String _kLrcLibBox = 'lrclib_lyrics';

// ── Strip common YouTube title noise ─────────────────────────────────────────

String _cleanYouTubeTitle(String title) {
  return title
      .replaceAllMapped(
        RegExp(
          r'\(.*?(official|video|audio|lyric|hd|hq|mv|4k|visualizer).*?\)',
          caseSensitive: false,
        ),
        (_) => '',
      )
      .replaceAllMapped(
        RegExp(
          r'\[.*?(official|video|audio|lyric|hd|hq|mv|4k|visualizer).*?\]',
          caseSensitive: false,
        ),
        (_) => '',
      )
      .replaceAllMapped(
        RegExp(
          r'[-|\u2014\u2013]\s*(official|lyrics?|audio|video|hd|mv).*',
          caseSensitive: false,
        ),
        (_) => '',
      )
      .replaceAll(
        RegExp(
          r'\b(MV|Music Video|Official Video|Official Audio)\b',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}

// ── Strip YouTube channel name noise (e.g. "Artist - Topic", "ArtistVEVO") ──

String _cleanArtistName(String name) {
  return name
      .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*VEVO\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*Official\s*$', caseSensitive: false), '')
      .trim();
}

// ── LRC parser ────────────────────────────────────────────────────────────────

List<LyricLine> _parseLrc(String lrc) {
  if (lrc.isEmpty) return [];

  final timestampRe = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');
  final results = <LyricLine>[];

  for (final rawLine in lrc.split('\n')) {
    final matches = timestampRe.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;

    final text = rawLine.replaceAll(timestampRe, '').trim();
    if (text.isEmpty) continue;

    for (final m in matches) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final fracStr = m.group(3)!;
      final frac = fracStr.length == 3
          ? int.parse(fracStr) / 1000.0
          : int.parse(fracStr) / 100.0;

      final totalMs = ((minutes * 60 + seconds + frac) * 1000).round();

      results.add(LyricLine(
        text: text,
        start: Duration(milliseconds: totalMs),
        end: Duration(milliseconds: totalMs + 4000),
        words: const [],
      ));
    }
  }

  results.sort((a, b) => a.start.compareTo(b.start));
  return results;
}

// ── Plain lyrics fallback ─────────────────────────────────────────────────────

List<LyricLine> _parsePlain(String plain) {
  return plain
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .map((l) => LyricLine(
            text: l,
            start: Duration.zero,
            end: Duration.zero,
          ))
      .toList();
}

// ── HTTP GET helper ───────────────────────────────────────────────────────────

Future<Map<String, dynamic>?> _get(String url) async {
  HttpClient? client;
  try {
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'Utify/1.0');
    request.headers.set('Accept', 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) return null;
    return jsonDecode(body) as Map<String, dynamic>?;
  } catch (_) {
    return null;
  } finally {
    client?.close();
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

class LrclibService {
  /// Fetch synced/plain lyrics for a song.
  ///
  /// Attempts (in order):
  ///   1. /get with title + cleaned artist + duration
  ///   2. /get with title + cleaned artist (no duration — mismatch is common)
  ///   3. /search fallback with "title artist" query
  Future<List<LyricLine>> fetchForSong(Song song) async {
    // 0. Cache lookup (videoId keyed)
    if (song.id.isNotEmpty) {
      final cached = await _readCachedLyrics(song.id);
      if (cached != null) return cached;
    }

    final cleanTitle = _cleanYouTubeTitle(song.title);
    final artist     = _cleanArtistName(song.channelName);

    List<LyricLine> resultLines = [];

    // ── Attempt 1: title + artist + duration ─────────────────────────────
    final params = <String, String>{
      'track_name':  cleanTitle,
      'artist_name': artist,
    };
    if (song.duration.inSeconds > 0) {
      params['duration'] = song.duration.inSeconds.toString();
    }

    final data = await _get('$_kBase/get?${_buildQuery(params)}');
    if (data != null) {
      resultLines = _extractFromMap(data);
      if (resultLines.isNotEmpty) {
        if (song.id.isNotEmpty) await _writeCachedLyrics(song.id, resultLines);
        return resultLines;
      }
    }

    // ── Attempt 2: title + artist WITHOUT duration ────────────────────────
    // LRCLIB uses duration for strict matching; omitting it is more lenient.
    if (song.duration.inSeconds > 0) {
      final paramsNoDur = <String, String>{
        'track_name':  cleanTitle,
        'artist_name': artist,
      };
      final data2 = await _get('$_kBase/get?${_buildQuery(paramsNoDur)}');
      if (data2 != null) {
        resultLines = _extractFromMap(data2);
        if (resultLines.isNotEmpty) {
          if (song.id.isNotEmpty) await _writeCachedLyrics(song.id, resultLines);
          return resultLines;
        }
      }
    }

    // ── Attempt 3: /search fallback ───────────────────────────────────────
    resultLines = await _searchFallback(cleanTitle, artist);
    if (song.id.isNotEmpty) {
      await _writeCachedLyrics(song.id, resultLines);
    }
    return resultLines;
  }

  List<LyricLine> _extractFromMap(Map<String, dynamic> data) {
    final syncedLrc   = data['syncedLyrics'] as String?;
    final plainLyrics = data['plainLyrics']  as String?;

    if (syncedLrc != null && syncedLrc.isNotEmpty) {
      final parsed = _parseLrc(syncedLrc);
      if (parsed.isNotEmpty) return parsed;
    }

    if (plainLyrics != null && plainLyrics.isNotEmpty) {
      return _parsePlain(plainLyrics);
    }

    return [];
  }

  static bool hasSyncedLyrics(List<LyricLine> lines) {
    if (lines.isEmpty) return false;
    return lines.any((l) => l.start != Duration.zero);
  }

  /// Reads cached lyrics for [videoId].
///
/// Returns:
/// - a list of lines if we have them cached
/// - an empty list if there's a negative cache entry ("no lyrics")
/// - null if there's no cached entry at all
Future<List<LyricLine>?> _readCachedLyrics(String videoId) async {
  try {
    final box = Hive.box(_kLrcLibBox);
    final record = box.get(videoId);
    if (record is! Map) return null;
    final type = record['type'];
    if (type == 'none') {
      // Negative cache: we already tried and found nothing.
      return const <LyricLine>[];
    }
    final syncedStr = record['synced'];
    final plainStr = record['plain'];
    if (syncedStr is String && syncedStr.isNotEmpty) {
      final parsed = _parseLrc(syncedStr);
      if (parsed.isNotEmpty) return parsed;
    }
    if (plainStr is String && plainStr.isNotEmpty) {
      final parsed = _parsePlain(plainStr);
      if (parsed.isNotEmpty) return parsed;
    }
  } catch (_) {
    // Cache read failures must not block playback.
  }
  return null;
}

Future<void> _writeCachedLyrics(String videoId, List<LyricLine> lines) async {
  try {
    final box = Hive.box(_kLrcLibBox);
    if (lines.isEmpty) {
      // Cache the negative result so repeated hits do not hit the network.
      await box.put(videoId, {'type': 'none'});
      return;
    }
    final isSynced = hasSyncedLyrics(lines);
    String? syncedStr;
    if (isSynced) {
      syncedStr = lines.map((l) => '[${l.start.inMilliseconds}]${l.text}').join('\n');
    }
    final plainStr = lines.map((l) => l.text).join('\n');
    await box.put(videoId, {
      'type': isSynced ? 'synced' : 'plain',
      if (syncedStr != null) 'synced': syncedStr,
      'plain': plainStr,
    });
  } catch (_) {
    // Cache write failures are best-effort.
  }
}

  String _buildQuery(Map<String, String> params) {
    return params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  Future<List<LyricLine>> _searchFallback(String title, String artist) async {
    final query = '$title $artist';
    final url   = '$_kBase/search?q=${Uri.encodeComponent(query)}';

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Utify/1.0');
      request.headers.set('Accept', 'application/json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return [];

      final list = jsonDecode(body);
      if (list is! List || list.isEmpty) return [];

      // Prefer synced lyrics first
      for (final item in list) {
        final map    = item as Map<String, dynamic>;
        final synced = map['syncedLyrics'] as String?;
        if (synced != null && synced.isNotEmpty) {
          final parsed = _parseLrc(synced);
          if (parsed.isNotEmpty) return parsed;
        }
      }
      // Fallback to plain lyrics
      for (final item in list) {
        final map   = item as Map<String, dynamic>;
        final plain = map['plainLyrics'] as String?;
        if (plain != null && plain.isNotEmpty) {
          return _parsePlain(plain);
        }
      }
    } catch (_) {
      return [];
    } finally {
      client?.close();
    }
    return [];
  }
}
