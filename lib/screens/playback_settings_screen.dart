// ============================================================
// screens/playback_settings_screen.dart
//
// Mobile playback preferences, reached from the account menu.
//
// Currently a single switch: autoplay radio — keep playing the song's
// YouTube Music radio ("fans of this song also listened to") after the
// queue ends, instead of stopping.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/theme/desktop_theme.dart';
import '../providers/playback_settings_provider.dart';

class PlaybackSettingsScreen extends ConsumerWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final autoplay = ref.watch(autoplayProvider);
    final notifier = ref.read(autoplayProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playback'),
        backgroundColor: theme.main,
        foregroundColor: theme.text,
      ),
      backgroundColor: theme.main,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: Text('Autoplay', style: TextStyle(color: theme.text)),
            subtitle: Text(
              'Keep playing similar songs — fans of the current song also '
              'listened to — when your music ends.',
              style: TextStyle(color: theme.subtext),
            ),
            value: autoplay,
            onChanged: notifier.setAutoplay,
            activeColor: theme.button,
            tileColor: theme.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ],
      ),
    );
  }
}
