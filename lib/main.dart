// ============================================================
// main.dart
// ============================================================

import 'package:audio_service/audio_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails, PlatformDispatcher, debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'dart:async';
import 'dart:io';

import 'firebase_options.dart';

import 'models/download_index.dart';
import 'models/song.dart';
import 'models/playlist.dart';
import 'services/download_index_service.dart';

import 'app.dart';
import 'services/audio_cache_service.dart';
import 'services/youtube_service.dart';
import 'services/ytmusic_feed_cache.dart';
import 'services/library_service.dart';
import 'services/audio_player_service.dart';
import 'services/audio_handler.dart';
import 'providers/player_provider.dart';
import 'providers/guest_session_provider.dart';
import 'desktop/theme/app_theme.dart';

/// Global handler — initialised once in main(), shared via provider.
late final TuneifyAudioHandler audioHandler;

Future<void> _initializeHive() async {
  await Hive.initFlutter();
  Hive.registerAdapter(SongAdapter());
  Hive.registerAdapter(PlaylistAdapter());
  Hive.registerAdapter(DownloadIndexEntryAdapter());

  await Future.wait([
    Hive.openBox<Song>('liked_songs'),
    Hive.openBox<Song>('recently_played'),
    Hive.openBox<Playlist>('playlists'),
    Hive.openBox<Song>('guest_liked_songs'),
    Hive.openBox<Song>('guest_recently_played'),
    Hive.openBox<Playlist>('guest_playlists'),
    Hive.openBox('settings'),
    Hive.openBox('stream_url_cache'),
    // LRU index for the private audio file cache (Android).
    Hive.openBox(kAudioCacheBox),
    // Disk tier for YT Music feeds.
    Hive.openBox(kYtMusicFeedBox),
    // Lyrics cache (LRCLIB) keyed by videoId.
    Hive.openBox('lrclib_lyrics'),
    // Rich download index (new in downloads-rework).
    Hive.openBox<DownloadIndexEntry>(kDownloadIndexBox),
    // Legacy download path map — kept open for one-time migration.
    // Opened as untyped Box<dynamic> so Hive never attempts a String cast
    // on values that may be booleans, ints, or other mixed types from the
    // original (untyped) box.
    Hive.openBox<dynamic>(kLegacyDownloadBox),
  ]);
}



Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Global error handlers ────────────────────────────────────────────────
  //
  // Without these, any unhandled async exception (e.g. inside a fire-and-
  // forget download) silently kills the Dart VM on Windows, which Flutter
  // reports as "Lost connection to device".
  //
  // FlutterError.onError  — catches errors thrown during widget builds,
  //   layout, painting, and other framework callbacks.
  // PlatformDispatcher.onError — catches all uncaught async exceptions in
  //   the root zone, including unawaited Futures.
  // runZonedGuarded        — catches uncaught errors in the zone that
  //   runApp() runs in (belt-and-suspenders with the above).

  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    if (kDebugMode) debugPrint('[FlutterError] stack:\n${details.stack}');
    // Do NOT rethrow — we want the app to stay alive.
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[PlatformDispatcher.onError] $error');
    if (kDebugMode) debugPrint('[PlatformDispatcher.onError] stack:\n$stack');
    return true; // returning true marks the error as handled
  };

  await runZonedGuarded(
    _appMain,
    (Object error, StackTrace stack) {
      debugPrint('[runZonedGuarded] unhandled: $error');
      if (kDebugMode) debugPrint('[runZonedGuarded] stack:\n$stack');
      // Do NOT rethrow — let the zone continue running.
    },
  );
}

/// The real main body, called inside the guarded zone.
Future<void> _appMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  final firebaseInit = Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  final hiveInit = _initializeHive();

  await firebaseInit;

  // Enable Firestore offline persistence.
  // On mobile this is the default; on Web/Desktop we enable it explicitly.
  // This lets the app read/write while offline and sync when back online.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  await hiveInit;
  final preferences = await SharedPreferences.getInstance();
  final guestMode = preferences.getBool('guest_session_active') ?? false;
  LibraryService.setGuestMode(guestMode);
  if (Platform.isWindows) {
    await AppThemeNotifier.restoreSavedTheme();
  }

  // Initialise the media_kit backend for Windows/Linux.
  // On Android, just_audio uses its own native backend — this call is a no-op.
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(
      windows: true,
      linux: true,
      android: false,
      iOS: false,
      macOS: false,
    );
  }

  // ── Audio handler initialisation ─────────────────────────────────────────
  //
  // audio_service only supports Android, iOS, macOS and Web.
  // On Windows it has no platform implementation — AudioService.init() calls
  // the builder but wraps the result in a stub that silently no-ops every
  // transport call (play, pause, skipToNext, …), making ALL playback broken.
  //
  // Fix: on Windows, construct TuneifyAudioHandler directly — no wrapping,
  // no stub.  just_audio + just_audio_media_kit handle the actual audio.
  // We simply don't get OS media-key integration on Windows (which
  // audio_service wouldn't provide anyway since it has no Windows impl).
  //
  // On Android/iOS/macOS AudioService.init keeps working normally for
  // lock-screen controls, notifications and the foreground service.
  if (Platform.isWindows || Platform.isLinux) {
    final yt = YoutubeService();
    final player = AudioPlayerService(yt);
    audioHandler = TuneifyAudioHandler(player);
  } else {
    audioHandler = await AudioService.init(
      builder: () {
        final yt = YoutubeService();
        final player = AudioPlayerService(yt);
        return TuneifyAudioHandler(player);
      },
      config: AudioServiceConfig(
        androidNotificationChannelId: Platform.isAndroid
            ? 'com.example.testf.channel.audio'
            : 'tuneify.desktop',
        androidNotificationChannelName:
            Platform.isAndroid ? 'Tuneify' : 'Tuneify',
        androidShowNotificationBadge: Platform.isAndroid,
        androidNotificationIcon: Platform.isAndroid
            ? 'drawable/ic_notification'
            : 'mipmap/ic_launcher',
        androidStopForegroundOnPause: !Platform.isAndroid,
        notificationColor: const Color(0xFF1DB954),
        artDownscaleWidth: 300,
        artDownscaleHeight: 300,
      ),
    );
  }

  // Restore local audio settings before the first frame. This prevents the
  // first playback request from using a default volume for one track.
  await audioHandler.service.initialize();

  runApp(ProviderScope(
    overrides: [
      // Give every provider in the tree the same handler instance that
      // audio_service registered — this is how playerProvider gets it.
      audioHandlerProvider.overrideWithValue(audioHandler),
      guestSessionProvider.overrideWith(
        (ref) => GuestSessionNotifier(guestMode),
      ),
    ],
    child: const TuneifyApp(),
  ));

  WidgetsBinding.instance.addPostFrameCallback((_) => _warmCache());
}

void _warmCache() {
  try {
    final lib = LibraryService();
    final yt = YoutubeService();

    // Signed stream URLs are dead weight once they fall inside the 10-minute
    // safety margin. Drop them before anything tries to read the box.
    unawaited(yt.pruneExpired());

    // Drop feed rows that can no longer be decoded, so one corrupt entry does
    // not force a full refetch of every shelf.
    unawaited(YtMusicFeedCache.instance.pruneBroken());

    // Download index startup maintenance: clean .part files, verify entries,
    // migrate legacy downloads, scan for unindexed files.
    unawaited(DownloadIndexService.instance.runStartupMaintenance());

    // Drop LRU rows whose files the OS already reclaimed, and trim back under

    // the user's limit before the first track tries to fill it again.
    // cacheDirectory() is warmed here too so the very first tap does not pay
    // for the path_provider round-trip.
    if (AudioCacheService.isSupported) {
      unawaited(() async {
        await AudioCacheService.instance.cacheDirectory();
        await AudioCacheService.instance.reconcile();
        await AudioCacheService.instance.evictIfNeeded();
      }());
    }

    final recent = lib.getRecentlyPlayed().take(6).toList();
    final liked = lib.getLikedSongs().take(4).toList();

    final Map<String, Song> byId = {};
    for (final s in [...recent, ...liked]) {
      byId[s.id] = s;
    }

    for (final song in byId.values) {
      yt.seedFromSong(song);
    }

    final needsFetch = byId.values
        .where((s) => s.isStreamUrlExpired)
        .map((s) => s.id)
        .toList();

    if (needsFetch.isNotEmpty) {
      yt.prefetchBatch(needsFetch, maxConcurrent: 3);
    }
  } catch (_) {}
}
