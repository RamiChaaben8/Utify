import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:utify/providers/playback_settings_provider.dart';
import 'package:utify/services/ytmusic_service.dart';

void main() {
  final service = YtMusicService.instance;

  Map<String, dynamic> panelItem({
    required String videoId,
    required String title,
    required String artist,
    String length = '3:25',
  }) =>
      {
        'playlistPanelVideoRenderer': {
          'videoId': videoId,
          'title': {
            'runs': [
              {'text': title}
            ]
          },
          'shortBylineText': {
            'runs': [
              {'text': artist}
            ]
          },
          'lengthText': {
            'runs': [
              {'text': length}
            ]
          },
        },
      };

  Map<String, dynamic> watchNextBody(List<Map<String, dynamic>> items) => {
        'contents': {
          'singleColumnMusicWatchNextResultsRenderer': {
            'tabbedRenderer': {
              'watchNextTabbedResultsRenderer': {
                'tabs': [
                  {
                    'tabRenderer': {
                      'title': 'Up next',
                      'content': {
                        'musicQueueRenderer': {
                          'content': {
                            'playlistPanelRenderer': {'contents': items},
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        },
      };

  group('getUpNext queue parsing', () {
    test('reads the Up next tab, skips the seed and de-dupes', () {
      final body = watchNextBody([
        panelItem(videoId: 'seed', title: 'Life Is Good', artist: 'Future'),
        panelItem(videoId: 'v1', title: 'Mask Off', artist: 'Future'),
        panelItem(
            videoId: 'v2', title: "God's Plan", artist: 'Drake', length: '3:19'),
        panelItem(videoId: 'v1', title: 'Mask Off', artist: 'Future'),
      ]);

      final songs = service.parseWatchNextQueue(body, 'seed');

      expect(songs.map((s) => s.videoId), ['v1', 'v2']);
      expect(songs.first.title, 'Mask Off');
      expect(songs.first.artist, 'Future');
      expect(songs.first.duration, const Duration(minutes: 3, seconds: 25));
      expect(songs.last.duration, const Duration(minutes: 3, seconds: 19));
    });

    test('returns empty when there is no queue tab', () {
      expect(service.parseWatchNextQueue(const {}, 'seed'), isEmpty);
    });

    test('drops junk-keyword titles and over-long tracks', () {
      final body = watchNextBody([
        panelItem(videoId: 'v1', title: 'Real Song', artist: 'A'),
        panelItem(videoId: 'v2', title: 'Real Song (slowed)', artist: 'B'),
        panelItem(videoId: 'v3', title: 'Long Mix', artist: 'C', length: '20:00'),
      ]);

      final songs = service.parseWatchNextQueue(body, 'seed');

      expect(songs.map((s) => s.videoId), ['v1']);
    });
  });

  group('automix id discovery', () {
    test('finds the RDAMVM id in a watchPlaybackEndpoint', () {
      expect(
        service.automixPlaylistId({
          'x': {
            'watchPlaybackEndpoint': {'playlistId': 'RDAMVMabc', 'params': 'p'}
          }
        }),
        'RDAMVMabc',
      );
    });

    test('finds the RDAMVM id in a watchEndpoint', () {
      expect(
        service.automixPlaylistId({
          'x': {
            'watchEndpoint': {'playlistId': 'RDAMVMabc'}
          }
        }),
        'RDAMVMabc',
      );
    });

    test('ignores non-automix playlist ids', () {
      expect(
        service.automixPlaylistId({
          'x': {
            'watchEndpoint': {'playlistId': 'PL123'}
          }
        }),
        isNull,
      );
    });
  });

  group('autoplay setting', () {
    late Directory dir;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('utify_settings_test');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    setUp(() async {
      await Hive.openBox('settings');
      await Hive.box('settings').clear();
    });

    test('defaults to enabled', () {
      expect(readAutoplaySetting(), isTrue);
    });

    test('persists a disabled choice', () async {
      final notifier = PlaybackSettingsNotifier();
      await notifier.setAutoplay(false);
      expect(readAutoplaySetting(), isFalse);
      expect(notifier.state, isFalse);
    });
  });
}
