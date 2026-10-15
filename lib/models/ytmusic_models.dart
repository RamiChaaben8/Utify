// lib/models/ytmusic_models.dart
// Immutable data models for the YouTube Music Innertube integration.
//
// Every model is a value object with hand-written `toJson` / `fromJson`
// rather than a Hive adapter: the feeds are cached as opaque JSON blobs in a
// single box, which lets a future schema change be a decode-time concern
// instead of an adapter migration. Decoders are therefore defensive — a
// missing or wrongly-typed field yields a sensible default rather than
// throwing, so one bad row can never wipe out an entire cached feed.

import 'artist_ref.dart';
import 'song.dart';
import '../utils/thumbnail_url.dart';

// ---------------------------------------------------------------------------
// JSON reading helpers
// ---------------------------------------------------------------------------

String _str(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String ? value : '';
}

String? _strOrNull(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String && value.isNotEmpty ? value : null;
}

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

/// Durations are stored as whole milliseconds — compact and lossless for the
/// lengths we deal with.
Duration _duration(Map<String, dynamic> json, String key) =>
    Duration(milliseconds: _int(json, key));

List<Map<String, dynamic>> _objList(dynamic raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

/// Decodes a cached `ArtistRef` list (each item `{'n': name, 'i': browseId}`).
List<ArtistRef> _artistRefs(dynamic raw) {
  if (raw is! List) return const [];
  final out = <ArtistRef>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final name = item['n'];
    if (name is! String || name.isEmpty) continue;
    final id = item['i'];
    out.add(ArtistRef(
      name: name,
      browseId: id is String && id.isNotEmpty ? id : null,
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// YtSong
// ---------------------------------------------------------------------------

class YtSong {
  final String videoId;
  final String title;
  final String artist;
  final String? album;
  final String coverUrl;
  final Duration duration;

  /// Per-artist references (name + browse id) when the source gave us the
  /// boundaries. Empty when only the joined [artist] string is known.
  final List<ArtistRef> artistRefs;

  const YtSong({
    required this.videoId,
    required this.title,
    required this.artist,
    this.album,
    required this.coverUrl,
    required this.duration,
    this.artistRefs = const [],
  });

  bool get isValid => videoId.isNotEmpty && title.isNotEmpty;

  Song toSong() => Song(
        id: videoId,
        title: title,
        channelName: artist,
        thumbnailUrl: ThumbnailUrl.normalize(coverUrl, videoId: videoId),
        duration: duration,
        artistNames: [for (final a in artistRefs) a.name],
        artistBrowseIds: [for (final a in artistRefs) a.browseId ?? ''],
      );

  @override
  bool operator ==(Object other) => other is YtSong && other.videoId == videoId;

  @override
  int get hashCode => videoId.hashCode;

  @override
  String toString() =>
      'YtSong(videoId: $videoId, title: $title, artist: $artist)';

  Map<String, dynamic> toJson() => {
        'id': videoId,
        't': title,
        'a': artist,
        if (album != null) 'b': album,
        'c': coverUrl,
        'd': duration.inMilliseconds,
        if (artistRefs.isNotEmpty)
          'r': [
            for (final a in artistRefs)
              {'n': a.name, if (a.hasBrowseId) 'i': a.browseId},
          ],
      };

  factory YtSong.fromJson(Map<String, dynamic> json) {
    final vId = _str(json, 'id');
    final rawCover = _str(json, 'c');
    return YtSong(
      videoId: vId,
      title: _str(json, 't'),
      artist: _str(json, 'a'),
      album: _strOrNull(json, 'b'),
      coverUrl: ThumbnailUrl.normalize(rawCover, videoId: vId),
      duration: _duration(json, 'd'),
      artistRefs: _artistRefs(json['r']),
    );
  }

  static List<Map<String, dynamic>> encodeList(List<YtSong> songs) =>
      [for (final song in songs) song.toJson()];

  static List<YtSong> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtSong.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtAlbumType
// ---------------------------------------------------------------------------

enum YtAlbumType { album, ep, single, unknown }

// ---------------------------------------------------------------------------
// YtAlbum
// ---------------------------------------------------------------------------

class YtAlbum {
  final String browseId;
  final String title;
  final String artist;
  final String coverUrl;
  final int? year;
  final YtAlbumType type;
  final bool isExplicit;

  const YtAlbum({
    required this.browseId,
    required this.title,
    required this.artist,
    required this.coverUrl,
    this.year,
    this.type = YtAlbumType.unknown,
    this.isExplicit = false,
  });

  bool get isValid => browseId.isNotEmpty && title.isNotEmpty;

  /// Human-readable type label: "Album", "EP", "Single".
  String get typeLabel {
    switch (type) {
      case YtAlbumType.album:
        return 'Album';
      case YtAlbumType.ep:
        return 'EP';
      case YtAlbumType.single:
        return 'Single';
      case YtAlbumType.unknown:
        return 'Album';
    }
  }

  /// Subtitle for display: "Album • Artist" or "EP • Artist".
  String get displaySubtitle {
    final artistStr = artist.isNotEmpty ? ' • $artist' : '';
    return '$typeLabel$artistStr';
  }

  @override
  bool operator ==(Object other) =>
      other is YtAlbum && other.browseId == browseId;

  @override
  int get hashCode => browseId.hashCode;

  @override
  String toString() =>
      'YtAlbum(browseId: $browseId, title: $title, artist: $artist, '
      'type: $type)';

  Map<String, dynamic> toJson() => {
        'id': browseId,
        't': title,
        'a': artist,
        'c': coverUrl,
        if (year != null) 'y': year,
        // Stored by name, not index, so reordering the enum cannot corrupt a
        // cache written by an older build.
        'k': type.name,
        'e': isExplicit,
      };

  factory YtAlbum.fromJson(Map<String, dynamic> json) {
    final rawType = json['k'];
    return YtAlbum(
      browseId: _str(json, 'id'),
      title: _str(json, 't'),
      artist: _str(json, 'a'),
      coverUrl: ThumbnailUrl.normalize(_str(json, 'c')),
      year: json['y'] is num ? (json['y'] as num).toInt() : null,
      type: rawType is String ? _albumTypeFromName(rawType) : YtAlbumType.unknown,
      isExplicit: json['e'] == true,
    );
  }

  static YtAlbumType _albumTypeFromName(String name) {
    for (final value in YtAlbumType.values) {
      if (value.name == name) return value;
    }
    return YtAlbumType.unknown;
  }

  static List<Map<String, dynamic>> encodeList(List<YtAlbum> albums) =>
      [for (final album in albums) album.toJson()];

  static List<YtAlbum> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtAlbum.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtArtist
// ---------------------------------------------------------------------------

class YtArtist {
  final String browseId;
  final String name;
  final String pictureUrl;

  const YtArtist({
    required this.browseId,
    required this.name,
    required this.pictureUrl,
  });

  bool get isValid => browseId.isNotEmpty && name.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is YtArtist && other.browseId == browseId;

  @override
  int get hashCode => browseId.hashCode;

  @override
  String toString() => 'YtArtist(browseId: $browseId, name: $name)';

  Map<String, dynamic> toJson() => {
        'id': browseId,
        'n': name,
        'p': pictureUrl,
      };

  factory YtArtist.fromJson(Map<String, dynamic> json) => YtArtist(
        browseId: _str(json, 'id'),
        name: _str(json, 'n'),
        pictureUrl: ThumbnailUrl.normalize(_str(json, 'p')),
      );

  static List<Map<String, dynamic>> encodeList(List<YtArtist> artists) =>
      [for (final artist in artists) artist.toJson()];

  static List<YtArtist> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtArtist.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtPlaylist
// ---------------------------------------------------------------------------

class YtPlaylist {
  final String browseId;
  final String title;
  final String subtitle;
  final String coverUrl;

  const YtPlaylist({
    required this.browseId,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
  });

  bool get isValid => browseId.isNotEmpty && title.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is YtPlaylist && other.browseId == browseId;

  @override
  int get hashCode => browseId.hashCode;

  @override
  String toString() => 'YtPlaylist(browseId: $browseId, title: $title)';

  Map<String, dynamic> toJson() => {
        'id': browseId,
        't': title,
        's': subtitle,
        'c': coverUrl,
      };

  factory YtPlaylist.fromJson(Map<String, dynamic> json) => YtPlaylist(
        browseId: _str(json, 'id'),
        title: _str(json, 't'),
        subtitle: _str(json, 's'),
        coverUrl: ThumbnailUrl.normalize(_str(json, 'c')),
      );

  static List<Map<String, dynamic>> encodeList(List<YtPlaylist> playlists) =>
      [for (final playlist in playlists) playlist.toJson()];

  static List<YtPlaylist> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtPlaylist.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtMoodChip
// ---------------------------------------------------------------------------

class YtMoodChip {
  final String label;
  final String params;

  const YtMoodChip({required this.label, required this.params});

  bool get isValid => label.isNotEmpty && params.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is YtMoodChip && other.label == label && other.params == params;

  @override
  int get hashCode => Object.hash(label, params);

  @override
  String toString() => 'YtMoodChip(label: $label)';

  Map<String, dynamic> toJson() => {'l': label, 'p': params};

  factory YtMoodChip.fromJson(Map<String, dynamic> json) => YtMoodChip(
        label: _str(json, 'l'),
        params: _str(json, 'p'),
      );

  static List<Map<String, dynamic>> encodeList(List<YtMoodChip> chips) =>
      [for (final chip in chips) chip.toJson()];

  static List<YtMoodChip> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtMoodChip.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtSection  — one horizontal shelf on the home / explore page
// ---------------------------------------------------------------------------

class YtSection {
  final String title;
  final List<YtSong> songs;
  final List<YtAlbum> albums;
  final List<YtArtist> artists;
  final List<YtPlaylist> playlists;

  const YtSection({
    required this.title,
    required this.songs,
    required this.albums,
    required this.artists,
    required this.playlists,
  });

  bool get isNotEmpty =>
      songs.isNotEmpty ||
      albums.isNotEmpty ||
      artists.isNotEmpty ||
      playlists.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is YtSection && other.title == title;

  @override
  int get hashCode => title.hashCode;

  @override
  String toString() =>
      'YtSection(title: $title, songs: ${songs.length}, '
      'albums: ${albums.length}, artists: ${artists.length}, '
      'playlists: ${playlists.length})';

  Map<String, dynamic> toJson() => {
        't': title,
        // Only the populated shelves are stored, so a section that was empty
        // when cached costs almost nothing on disk.
        if (songs.isNotEmpty) 's': YtSong.encodeList(songs),
        if (albums.isNotEmpty) 'a': YtAlbum.encodeList(albums),
        if (artists.isNotEmpty) 'r': YtArtist.encodeList(artists),
        if (playlists.isNotEmpty) 'p': YtPlaylist.encodeList(playlists),
      };

  factory YtSection.fromJson(Map<String, dynamic> json) => YtSection(
        title: _str(json, 't'),
        songs: YtSong.decodeList(json['s']),
        albums: YtAlbum.decodeList(json['a']),
        artists: YtArtist.decodeList(json['r']),
        playlists: YtPlaylist.decodeList(json['p']),
      );

  static List<Map<String, dynamic>> encodeList(List<YtSection> sections) =>
      [for (final section in sections) section.toJson()];

  static List<YtSection> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtSection.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// Envelope readers
//
// A cached feed is always stored as one JSON object. List-shaped feeds live
// under `items`; these readers accept either that envelope or a bare list, so
// they work for both the on-disk shape and an inline literal.
// ---------------------------------------------------------------------------

List<YtSection> ytSectionListFrom(dynamic json) =>
    YtSection.decodeList(json is Map ? json['items'] : json);

List<YtSong> ytSongListFrom(dynamic json) =>
    YtSong.decodeList(json is Map ? json['items'] : json);

List<YtArtist> ytArtistListFrom(dynamic json) =>
    YtArtist.decodeList(json is Map ? json['items'] : json);

List<YtAlbum> ytAlbumListFrom(dynamic json) =>
    YtAlbum.decodeList(json is Map ? json['items'] : json);

List<YtMoodChip> ytMoodChipListFrom(dynamic json) =>
    YtMoodChip.decodeList(json is Map ? json['items'] : json);

// ---------------------------------------------------------------------------
// YtArtistData — one artist's full page (header + shelves)
// ---------------------------------------------------------------------------

class YtArtistData {
  final String browseId;
  final String name;
  final String pictureUrl;
  final String description;
  final String subscribers;
  final List<YtSong> topSongs;
  final List<YtAlbum> albums;
  final List<YtAlbum> singles;
  final List<YtArtist> relatedArtists;

  const YtArtistData({
    required this.browseId,
    required this.name,
    required this.pictureUrl,
    this.description = '',
    this.subscribers = '',
    this.topSongs = const [],
    this.albums = const [],
    this.singles = const [],
    this.relatedArtists = const [],
  });

  bool get isValid => browseId.isNotEmpty && name.isNotEmpty;

  bool get hasContent =>
      topSongs.isNotEmpty ||
      albums.isNotEmpty ||
      singles.isNotEmpty ||
      relatedArtists.isNotEmpty;

  @override
  String toString() =>
      'YtArtistData(browseId: $browseId, name: $name, '
      'songs: ${topSongs.length}, albums: ${albums.length}, '
      'singles: ${singles.length}, related: ${relatedArtists.length})';

  Map<String, dynamic> toJson() => {
        'id': browseId,
        'n': name,
        'p': pictureUrl,
        if (description.isNotEmpty) 'd': description,
        if (subscribers.isNotEmpty) 'sub': subscribers,
        if (topSongs.isNotEmpty) 's': YtSong.encodeList(topSongs),
        if (albums.isNotEmpty) 'a': YtAlbum.encodeList(albums),
        if (singles.isNotEmpty) 'si': YtAlbum.encodeList(singles),
        if (relatedArtists.isNotEmpty) 'r': YtArtist.encodeList(relatedArtists),
      };

  factory YtArtistData.fromJson(Map<String, dynamic> json) => YtArtistData(
        browseId: _str(json, 'id'),
        name: _str(json, 'n'),
        pictureUrl: ThumbnailUrl.normalize(_str(json, 'p')),
        description: _str(json, 'd'),
        subscribers: _str(json, 'sub'),
        topSongs: YtSong.decodeList(json['s']),
        albums: YtAlbum.decodeList(json['a']),
        singles: YtAlbum.decodeList(json['si']),
        relatedArtists: YtArtist.decodeList(json['r']),
      );

  static List<Map<String, dynamic>> encodeList(List<YtArtistData> artists) =>
      [for (final artist in artists) artist.toJson()];

  static List<YtArtistData> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtArtistData.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// YtSearchResults — mixed search results (songs + artists + albums)
// ---------------------------------------------------------------------------

class YtSearchResults {
  final List<YtSong> songs;
  final List<YtArtist> artists;
  final List<YtAlbum> albums;

  const YtSearchResults({
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
  });

  bool get isEmpty => songs.isEmpty && artists.isEmpty && albums.isEmpty;

  Map<String, dynamic> toJson() => {
        if (songs.isNotEmpty) 's': YtSong.encodeList(songs),
        if (artists.isNotEmpty) 'r': YtArtist.encodeList(artists),
        if (albums.isNotEmpty) 'a': YtAlbum.encodeList(albums),
      };

  factory YtSearchResults.fromJson(Map<String, dynamic> json) =>
      YtSearchResults(
        songs: YtSong.decodeList(json['s']),
        artists: YtArtist.decodeList(json['r']),
        albums: YtAlbum.decodeList(json['a']),
      );

  static List<Map<String, dynamic>> encodeList(List<YtSearchResults> results) =>
      [for (final result in results) result.toJson()];

  static List<YtSearchResults> decodeList(dynamic raw) => [
        for (final json in _objList(raw)) YtSearchResults.fromJson(json),
      ];
}

// ---------------------------------------------------------------------------
// Single-object envelope readers (artist page, mixed search)
// ---------------------------------------------------------------------------

YtArtistData ytArtistDataFrom(dynamic json) => YtArtistData.fromJson(
      json is Map ? Map<String, dynamic>.from(json) : const {},
    );

YtSearchResults ytSearchResultsFrom(dynamic json) => YtSearchResults.fromJson(
      json is Map ? Map<String, dynamic>.from(json) : const {},
    );
