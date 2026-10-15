// ============================================================
// models/song.dart — Song data model stored in Hive
// ============================================================

import 'package:hive/hive.dart';

import 'artist_ref.dart';

part 'song.g.dart';

@HiveType(typeId: 0)
class Song extends HiveObject {
  @HiveField(0)
  final String id; // YouTube video ID (or file path for local songs)

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String channelName;

  @HiveField(3)
  final String thumbnailUrl;

  @HiveField(4)
  final Duration duration;

  @HiveField(5)
  final String? streamUrl; // Cached stream URL (expires ~6h)

  @HiveField(6)
  final DateTime? streamUrlFetchedAt; // For expiry checks

  @HiveField(7)
  final bool isLocal; // true = downloaded file on device

  @HiveField(8)
  final String? localPath; // absolute path to the local file

  /// Credited artist names, in source order. Parallel to [artistBrowseIds].
  /// Empty for records written before this field existed — use [artistRefs],
  /// which falls back to a single [channelName] reference.
  @HiveField(9)
  final List<String> artistNames;

  /// Browse ids parallel to [artistNames]; "" where the source gave no id.
  @HiveField(10)
  final List<String> artistBrowseIds;

  Song({
    required this.id,
    required this.title,
    required this.channelName,
    required this.thumbnailUrl,
    required this.duration,
    this.streamUrl,
    this.streamUrlFetchedAt,
    this.isLocal = false,
    this.localPath,
    this.artistNames = const [],
    this.artistBrowseIds = const [],
  });

  /// Structured artist references for display/linking.
  ///
  /// Falls back to a single [channelName] reference when no per-artist data was
  /// stored (older records, or sources that only carry one string).
  List<ArtistRef> get artistRefs {
    if (artistNames.isEmpty) {
      return channelName.trim().isEmpty
          ? const []
          : [ArtistRef(name: channelName)];
    }
    return [
      for (var i = 0; i < artistNames.length; i++)
        ArtistRef(
          name: artistNames[i],
          browseId: i < artistBrowseIds.length && artistBrowseIds[i].isNotEmpty
              ? artistBrowseIds[i]
              : null,
        ),
    ];
  }

  Song copyWith({
    String? streamUrl,
    DateTime? streamUrlFetchedAt,
    bool? isLocal,
    String? localPath,
    List<String>? artistNames,
    List<String>? artistBrowseIds,
  }) {
    return Song(
      id: id,
      title: title,
      channelName: channelName,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      streamUrl: streamUrl ?? this.streamUrl,
      streamUrlFetchedAt: streamUrlFetchedAt ?? this.streamUrlFetchedAt,
      isLocal: isLocal ?? this.isLocal,
      localPath: localPath ?? this.localPath,
      artistNames: artistNames ?? this.artistNames,
      artistBrowseIds: artistBrowseIds ?? this.artistBrowseIds,
    );
  }

  bool get isStreamUrlExpired {
    if (streamUrl == null || streamUrlFetchedAt == null) return true;
    return DateTime.now().difference(streamUrlFetchedAt!) > const Duration(hours: 5);
  }

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
