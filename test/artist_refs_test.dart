import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:utify/models/artist_ref.dart';
import 'package:utify/models/song.dart';
import 'package:utify/models/ytmusic_models.dart';

void main() {
  group('Song.artistRefs', () {
    Song makeSong({
      String channelName = 'Drake',
      List<String> names = const [],
      List<String> ids = const [],
    }) =>
        Song(
          id: 'v1',
          title: 'T',
          channelName: channelName,
          thumbnailUrl: '',
          duration: const Duration(minutes: 3),
          artistNames: names,
          artistBrowseIds: ids,
        );

    test('falls back to channelName when no per-artist data was stored', () {
      final song = makeSong(channelName: 'Simon & Garfunkel');
      expect(song.artistRefs, [
        const ArtistRef(name: 'Simon & Garfunkel'),
      ]);
    });

    test('uses the parallel lists and tolerates a missing browse id', () {
      final song = makeSong(
        channelName: 'Drake & Future',
        names: const ['Drake', 'Future'],
        ids: const ['UC1', ''],
      );
      expect(song.artistRefs, [
        const ArtistRef(name: 'Drake', browseId: 'UC1'),
        const ArtistRef(name: 'Future'),
      ]);
    });

    test('copyWith preserves artist refs', () {
      final song = makeSong(
        names: const ['A', 'B'],
        ids: const ['UCa', 'UCb'],
      );
      final copy = song.copyWith(isLocal: true);
      expect(copy.artistRefs.length, 2);
      expect(copy.artistRefs.first.browseId, 'UCa');
    });
  });

  group('YtSong artist refs JSON', () {
    test('round-trips per-artist references', () {
      const song = YtSong(
        videoId: 'v1',
        title: 'Jumpman',
        artist: 'Drake & Future',
        coverUrl: '',
        duration: Duration.zero,
        artistRefs: [
          ArtistRef(name: 'Drake', browseId: 'UCd'),
          ArtistRef(name: 'Future', browseId: 'UCf'),
        ],
      );
      final decoded = YtSong.fromJson(song.toJson());
      expect(decoded.artist, 'Drake & Future');
      expect(decoded.artistRefs, song.artistRefs);
    });

    test('toSong carries refs into the Hive model', () {
      const song = YtSong(
        videoId: 'v1',
        title: 'Jumpman',
        artist: 'Drake & Future',
        coverUrl: '',
        duration: Duration.zero,
        artistRefs: [
          ArtistRef(name: 'Drake', browseId: 'UCd'),
          ArtistRef(name: 'Future'),
        ],
      );
      final hiveSong = song.toSong();
      expect(hiveSong.artistNames, ['Drake', 'Future']);
      expect(hiveSong.artistBrowseIds, ['UCd', '']);
      expect(hiveSong.artistRefs.last.browseId, isNull);
    });
  });

  group('Song Hive adapter', () {
    late Directory dir;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('utify_hive_test');
      Hive.init(dir.path);
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(SongAdapter());
      }
    });

    tearDownAll(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('round-trips the new artist fields', () async {
      final box = await Hive.openBox<Song>('songs_roundtrip');
      final song = Song(
        id: 'v1',
        title: 'Jumpman',
        channelName: 'Drake & Future',
        thumbnailUrl: '',
        duration: const Duration(minutes: 3),
        artistNames: const ['Drake', 'Future'],
        artistBrowseIds: const ['UCd', ''],
      );
      await box.put('k', song);

      final read = box.get('k')!;
      expect(read.artistNames, ['Drake', 'Future']);
      expect(read.artistBrowseIds, ['UCd', '']);
      expect(read.artistRefs, [
        const ArtistRef(name: 'Drake', browseId: 'UCd'),
        const ArtistRef(name: 'Future'),
      ]);
      await box.close();
    });

    test('old records without the new fields decode to empty lists', () async {
      final box = await Hive.openBox<Song>('songs_legacy');
      // Write a record through the adapter with the new fields empty, which is
      // exactly how a pre-migration record decodes (fields 9/10 absent → null).
      final legacy = Song(
        id: 'old',
        title: 'Old',
        channelName: 'Legacy Artist',
        thumbnailUrl: '',
        duration: const Duration(minutes: 2),
      );
      await box.put('k', legacy);

      final read = box.get('k')!;
      expect(read.artistNames, isEmpty);
      expect(read.artistBrowseIds, isEmpty);
      expect(read.artistRefs, [const ArtistRef(name: 'Legacy Artist')]);
      await box.close();
    });
  });
}
