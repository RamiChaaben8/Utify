import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:utify/services/youtube_service.dart';

SearchVideo _video({
  String id = '6f8gDL-wPN8',
  String title = 'Mask Off',
  String author = 'Future',
  String duration = '3:24',
  String? uploadDate,
}) =>
    SearchVideo(
      VideoId(id),
      title,
      author,
      '',
      duration,
      1000,
      const [],
      uploadDate,
      false,
      'UC-channel',
    );

void main() {
  group('search result mapping', () {
    test('maps a result whose upload date is a bare "Streamed"', () {
      // `YoutubeExplode.search.search` runs every `uploadDate` through
      // `String.toDateTime()`, which `int.parse`s the first word. A live-stream
      // timestamp like "Streamed" throws there and aborts the whole search;
      // our mapper must ignore the timestamp entirely.
      final song = YoutubeService.searchVideoToSong(_video(uploadDate: 'Streamed'));

      expect(song.id, '6f8gDL-wPN8');
      expect(song.title, 'Mask Off');
      expect(song.channelName, 'Future');
      expect(song.thumbnailUrl, contains('6f8gDL-wPN8'));
      expect(song.duration, const Duration(minutes: 3, seconds: 24));
    });

    test('maps a normal result', () {
      final song = YoutubeService.searchVideoToSong(
        _video(title: 'God\'s Plan', uploadDate: '5 years ago'),
      );

      expect(song.title, 'God\'s Plan');
      expect(song.duration, const Duration(minutes: 3, seconds: 24));
    });
  });

  group('duration parsing', () {
    test('parses MM:SS and HH:MM:SS', () {
      expect(
        YoutubeService.parseDurationText('4:05'),
        const Duration(minutes: 4, seconds: 5),
      );
      expect(
        YoutubeService.parseDurationText('1:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
    });

    test('returns zero for empty or malformed input', () {
      expect(YoutubeService.parseDurationText(''), Duration.zero);
      expect(YoutubeService.parseDurationText('LIVE'), Duration.zero);
      expect(YoutubeService.parseDurationText('1:2:3:4'), Duration.zero);
      expect(YoutubeService.parseDurationText('abc:def'), Duration.zero);
    });
  });
}
