// ============================================================
// providers/playback_settings_provider.dart
//
// Playback preferences that live in the shared Hive `settings` box.
//
// Currently a single switch: autoplay radio ("Autoplay similar songs when
// your music ends"). When a queue runs out, the player tops it up with
// YouTube Music's per-song radio, the way Spotify continues past the end of
// an album or a one-off play.
//
// The player provider is not `ref`-scoped, so it reads the same Hive key
// directly via [kAutoplaySettingKey] / [readAutoplaySetting]; this provider
// exists to drive the UI and keep the two in sync.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

/// Hive key for the autoplay preference.
const String kAutoplaySettingKey = 'autoplay';

/// Reads the autoplay preference straight from Hive. Defaults to `true`.
///
/// Safe to call before the box is ready — returns the default on any error.
bool readAutoplaySetting() {
  try {
    return Hive.box('settings').get(kAutoplaySettingKey) as bool? ?? true;
  } catch (_) {
    return true;
  }
}

class PlaybackSettingsNotifier extends StateNotifier<bool> {
  PlaybackSettingsNotifier() : super(readAutoplaySetting());

  /// Enable or disable autoplay radio, persisting the choice.
  Future<void> setAutoplay(bool enabled) async {
    try {
      await Hive.box('settings').put(kAutoplaySettingKey, enabled);
    } catch (_) {}
    if (mounted) state = enabled;
  }
}

/// `true` when autoplay radio is enabled. Defaults to enabled.
final autoplayProvider =
    StateNotifierProvider<PlaybackSettingsNotifier, bool>((ref) {
  return PlaybackSettingsNotifier();
});
