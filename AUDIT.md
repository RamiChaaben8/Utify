# Flutter performance audit: Utify (Android)

**Scope.** I reviewed everything Android-relevant in the files you attached and skipped `lib/desktop/*` and `windows/*`. I did not have `pubspec.yaml`, your Flutter version, or the resolved minSdk, so items marked **(verify)** are inferences. My questions are at the end. Time and memory gains are estimates, so confirm them with the DevTools checklist.

---

## TOP 5 highest-impact problems

### 1. CRITICAL: the whole PlayerState and DownloadState are rebuilt thousands of times

**What's wrong**

- `PlayerNotifier` writes a new `PlayerState` every 400 ms because of `position`.
- `SearchScreen`, `PlaylistScreen`, `NowPlayingScreen`, `MiniPlayer` and `QueueScreen` all call `ref.watch(playerProvider)` with no `select`. Every result list and the lyrics page rebuild about 2.5 times per second.
- It is worse during downloads. `DownloadService` calls `_changeController.add(null)` for every network chunk (a few KB each, up to 3 downloads at once). Each call makes `DownloadNotifier._rebuild()` copy the task map and run `DownloadIndexService.getAll()` (`box.values.toList()`), then publish a new state.
- `SongTile` and `PlaylistScreen` watch the whole `downloadProvider`, so every visible row rebuilds on every chunk.
- `PlaylistScreen.build` also loops over every song several times, doing a Hive `containsKey` per song, on every tick.

**Why it's slow.** On a 2 GB phone this fills the UI thread with rebuilds, so frames take 20–40 ms during playback and fall below 20 fps during downloads.

**Fix.** You already do this correctly in `AppShell` (`playerProvider.select(...)`). Apply it everywhere.

```dart
// SearchScreen / PlaylistScreen / QueueScreen / SongTile hosts
final currentId = ref.watch(playerProvider.select((s) => s.currentSong?.id));
final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
```

```dart
// MiniPlayer: isolate the only widget that needs position
class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider.select((s) =>
        s.duration.inMilliseconds > 0
            ? (s.position.inMilliseconds / s.duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0));
    return LinearProgressIndicator(value: p, minHeight: 2);
  }
}
```

In `NowPlayingScreen`, `_PlayerPage` and `_LyricsPage` take the whole `playerState`. Move `SeekBar`, the current-lyric line and `_LyricsPage` into small consumers that select only `position`.

```dart
// SongTile
final dl = ref.watch(downloadProvider.select((s) => (
  s.isDownloaded(song.id),
  s.isDownloading(song.id),
  (s.progressFor(song.id) * 20).round(), // 5% steps; records compare by value
)));
```

```dart
// DownloadService: throttle progress notifications
DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
void _notifyProgress() {
  final now = DateTime.now();
  if (now.difference(_lastProgressNotify) < const Duration(milliseconds: 300)) return;
  _lastProgressNotify = now;
  _notify();
}
// replace every `_changeController.add(null)` inside the chunk loops with _notifyProgress()
```

In `DownloadNotifier._rebuild`, recompute `downloaded` only when a task finishes or is deleted, not on every progress tick. Also replace `MediaQuery.of(context).size` with `MediaQuery.sizeOf(context)` in `NowPlayingScreen`.

**Expected gain.** Rebuilds drop from hundreds per second to a few. I'd expect UI frame time during playback and download to fall from roughly 20–40 ms to under 8 ms on a low-end device.

---

### 2. CRITICAL: thumbnails are decoded at full resolution (the main RAM and jank risk on 2 GB devices)

**What's wrong**

- `YoutubeService._videoToSong` picks `maxResUrl` first, so every search result starts as a 1280×720 JPEG. Your own comments note that this URL often returns 404.
- `AppThumbnail`, `SongTile` and `NowPlayingScreen` show 44–140 px thumbnails with no `memCacheWidth`/`Height`. Flutter decodes the full bitmap, about 3.7 MB each.
- `ArtworkCacheManager` exists but is only used in `MiniPlayer`.
- `ThumbnailUrl.normalize` upsizes Google CDN images to 544 px, even for 56 px tiles.
- `AppThumbnail.errorWidget` calls `setState` through `_handleError` during a build. That raises "setState during build" errors and can cause rebuild loops.
- No image-cache cap is set, although `cache_support.dart` mentions "image cache tuning".

**Fix**

```dart
// app_thumbnail.dart
final dpr = MediaQuery.devicePixelRatioOf(context);
CachedNetworkImage(
  imageUrl: effectiveUrl,
  cacheManager: ArtworkCacheManager.instance,
  memCacheWidth: widget.width == null ? null : (widget.width! * dpr).round(),
  memCacheHeight: widget.height == null ? null : (widget.height! * dpr).round(),
  // ...
  errorWidget: (ctx, url, err) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleError(err, null));
    return errorWidget;
  },
)
```

```dart
// youtube_service.dart: use mqdefault (320x180) for list/tile thumbs, hqdefault for large art
thumbnailUrl: 'https://i.ytimg.com/vi/${video.id.value}/mqdefault.jpg',
```

```dart
// main.dart, after ensureInitialized(): cap the decoded-image cache
PaintingBinding.instance.imageCache
  ..maximumSizeBytes = 60 << 20   // 60 MB (default is 100 MB)
  ..maximumSize = 150;
```

Also apply `memCacheWidth` to the 4-image mosaics in `library_screen.dart`. They currently decode four full images per playlist tile.

**Expected gain.** Image memory drops from tens of MB per screen to a few MB. That means fewer GC pauses and lower OOM risk on 2 GB devices, plus faster list scrolling.

---

### 3. CRITICAL: the streaming and cache pipeline wastes data and storage, and the cache evictor has a bug

#### 3a. Eviction bug

In `AudioCacheService.evictIfNeeded`:

```dart
await delete(entry.key);
final record = _entry(entry.key);          // already deleted → null
final size = (record?['sizeBytes'] as int?) ?? 0;   // always 0
total -= size;                              // never decreases
```

`total` never goes down, so the loop never reaches `if (total <= limit) break`. Once the cache exceeds its limit, it deletes every unprotected file. `PrefetchService.trimCache()` calls `evictIfNeeded()` with no `protect` set, so it deletes the tracks it just prefetched. On top of that, each `delete()` calls `_notifySize()`, which runs a full `stats()` scan (an `exists()` plus `length()` for every file). A big eviction is therefore O(n²) disk I/O.

```dart
for (final entry in entries) {
  if (total <= limit) break;
  final size = (_entry(entry.key)?['sizeBytes'] as int?) ?? 0; // read BEFORE delete
  await delete(entry.key, notify: false);
  total -= size; freed += size;
}
await _notifySize(); // once
```

Add `{bool notify = true}` to `delete()`, and pass `protect` from `trimCache`.

#### 3b. Playback and cache use muxed video+audio streams

`getAudioStreamCandidates` puts `muxedMp4` first, sorted by ascending bitrate. That is the lowest-quality video stream including its video track, and `LockCachingAudioSource` writes the whole thing to disk as `.m4a`. `DownloadService._bestAudioStream` also prefers muxed mp4, because you saw HTTP 403 on audio-only URLs. So every cached or downloaded song is typically 3–5× larger than an audio-only stream (a 360p muxed file is about 500 kbps, versus 128 kbps for itag 140), and it uses that much more battery and data.

I can't tell from the code why audio-only failed, so I won't guess a fix (see question 3). Two directions to try:

- If your `youtube_explode_dart` version supports it, request the manifest with a different client, for example `getManifest(id, ytClients: [YoutubeApiClient.androidVr])`. Audio-only URLs often work with that client.
- If audio-only genuinely stalls on some devices, keep muxed only as the fallback, not the first choice.

#### 3c. Prefetch is aggressive

It downloads whole files for the next 2 tracks, plus the player caches the current one in full. Skipping a song wastes everything fetched so far. Set `kPrefetchDepth = 1`. Prefetch only the stream URL on mobile data (the Wi-Fi rule is already there), and consider also requiring battery above 20% or charging.

**Expected gain.** Roughly 3–4× less cache and download storage and traffic once audio-only works. The eviction fix stops the cache from being repeatedly wiped.

---

### 4. CRITICAL: startup does too much before and right after the first frame

**What's wrong**

- `_initializeHive` opens 13 boxes before `runApp`. Hive loads each box fully into RAM on open. `lrclib_lyrics` (full lyric text per song, never pruned) and `ytmusic_feed_cache` (up to 4 MB per feed) grow without bound. The three guest boxes are opened even for signed-in users.
- `AppShell` puts `HomeScreen`, `SearchScreen`, `LibraryScreen` and `FriendsScreen` in an `IndexedStack`, which builds all four at once. That means the YT Music feed fetch, the friends stream and the library scans all start at first paint.
- `FirebaseFirestore.settings.cacheSizeBytes: CACHE_SIZE_UNLIMITED` lets the Firestore cache grow without limit on low-storage phones.
- There are three separate `YoutubeService` / `YoutubeExplode` instances: the player's, `youtubeServiceProvider`'s, and one created in `_warmCache()` that is never disposed. `_warmCache` calls `seedFromSong` on that throwaway instance, so the seed is wasted. The `prefetchUrl` calls from `SongTile` warm yet another instance's memory cache.
- Splash: `LaunchTheme` shows a plain white window (and `?android:colorBackground` on v21), but the app is `#0A0A0A`. Light-mode phones get a white flash on every cold start.
- `WidgetsFlutterBinding.ensureInitialized()` runs in `main()` and again inside `runZonedGuarded`, which gives the Flutter "zone mismatch" warning.

**Fix**

```dart
// 1) Only critical boxes before runApp; lazy for big/rare ones
await Future.wait([
  Hive.openBox<Song>('liked_songs'),
  Hive.openBox<Song>('recently_played'),
  Hive.openBox<Playlist>('playlists'),
  Hive.openBox('settings'),
  Hive.openBox('stream_url_cache'),
  Hive.openBox<DownloadIndexEntry>(kDownloadIndexBox),
]);
// open lazily when first needed:
Hive.openLazyBox('lrclib_lyrics');         // then `await box.get(id)` in LrclibService
Hive.openLazyBox(kYtMusicFeedBox);         // YtMusicFeedCache is already async
// guest_* boxes: open in GuestSessionNotifier.enterGuest()
```

```dart
// 2) Lazy tabs
final _visited = <int>{0};
IndexedStack(
  index: _currentIndex,
  children: [
    for (var i = 0; i < screens.length; i++)
      _visited.contains(i) ? screens[i] : const SizedBox.shrink(),
  ],
)
// onTap: setState(() { _currentIndex = i; _visited.add(i); });
```

```dart
// 3) Single YoutubeService
ProviderScope(overrides: [
  audioHandlerProvider.overrideWithValue(audioHandler),
  youtubeServiceProvider.overrideWithValue(audioHandler.service.youtubeService),
  ...
])
// _warmCache: use audioHandler.service.youtubeService instead of YoutubeService()
```

```dart
// 4) Firestore
FirebaseFirestore.instance.settings = const Settings(
  persistenceEnabled: true,
  cacheSizeBytes: 100 * 1024 * 1024,
);
```

```xml
<!-- res/values/styles.xml AND values-night/styles.xml: dark launch bg -->
<item name="android:windowBackground">@drawable/launch_background</item>
<!-- launch_background.xml (both drawable/ and drawable-v21/): -->
<item android:drawable="@color/tuneify_bg" />   <!-- or #0A0A0A -->
```

For Android 12+, also add `res/values-v31/styles.xml` with `<item name="android:windowSplashScreenBackground">#0A0A0A</item>`.

If you want the first frame even sooner, call `runApp` with a lightweight `BootstrapApp` and move `Firebase.initializeApp` plus the Hive boxes behind a `FutureBuilder` or provider. Keep `AudioService.init` before the player UI, since it creates the handler. Remove the outer `runZonedGuarded`, or move `ensureInitialized` inside it.

**Expected gain.** Hive RAM drops by roughly the size of the feed and lyrics boxes, and cold start gets shorter, probably by hundreds of ms on a low-end device (measure with `--trace-startup`). Dropping the unneeded tabs removes network and Firestore work from the first second. The dark splash removes the white flash.

---

### 5. CRITICAL: background reliability and notifications (Android 13+, 14+ and OEM skins)

**What's wrong**

- **No `POST_NOTIFICATIONS`.** It is neither declared in `AndroidManifest.xml` nor requested in `MainActivity.requestStoragePermissions`. On Android 13+ the playback and download notifications are suppressed.
- **Downloads run inside the Dart process** with no foreground service or WorkManager. They are killed or throttled by Doze, App Standby, and Xiaomi/Huawei/Oppo/Samsung battery managers as soon as the app leaves the foreground without active playback. Resume-on-retry exists, but the process is simply gone.
- **Two notifications.** `MarqueeNotificationHelper` posts a second custom RemoteViews notification (ID 9999) on every state change, in addition to `audio_service`'s media notification. It downloads the full artwork with `URL(artUrl).openStream()` each time, with no cache and no timeout. `MarqueeButtonReceiver` calls `startForegroundService(...)` from a broadcast, and on Android 12+ this can throw `ForegroundServiceDidNotStartInTimeException` if the service doesn't call `startForeground()` in time.
- **Foreground service lifetime.** `androidStopForegroundOnPause: false` keeps the service in the foreground while paused. The notification can't be swiped away, and the service stays alive.
- **Battery.** The player writes a `remoteCommand` doc to Firestore every 5 s while playing (`PlayerNotifier`, the position-stream listener). It also does `_saveLocalPlaybackState` to Hive, and that doc carries up to 200 serialized songs each time. That is about 720 Firestore writes per hour per playing device, plus the 30 s device heartbeat and 60 s presence writes, so battery, mobile data and Firestore quota all suffer.

**Fix**

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

```kotlin
// MainActivity.requestStoragePermissions()
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
    ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
        != PackageManager.PERMISSION_GRANTED) {
    permsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
}
```

Request it in context, for example on the first play or the first download, not at launch.

- **Delete the Marquee notification** and rely on `audio_service`'s `MediaItem`/`MediaControl` notification, which already shows title, artist and art. If you want the "Next:" line, put it in `MediaItem.displaySubtitle`.
- **Downloads.** Use WorkManager or a foreground service. `background_downloader` handles resume, notifications and the Android 14 requirements:

```dart
final task = DownloadTask(
  url: streamUrl, filename: '$basename.$ext',
  headers: {'User-Agent': _ua}, directory: 'utify',
  baseDirectory: BaseDirectory.temporary,
  updates: Updates.statusAndProgress, requiresWiFi: !downloadOnMobile,
  retries: 3,
);
await FileDownloader().enqueue(task);
```

If you keep your own engine, run it inside a foreground service with `foregroundServiceType="dataSync"`. Add `FOREGROUND_SERVICE_DATA_SYNC` and declare the type on the `<service>`. Note that `dataSync` has a time cap on Android 15.

- **Firestore sync.** Stop the 5 s timer. Write on pause, seek, track change and background. While playing, write at most every 30–60 s, and only when another device is registered. Send position-only updates without the queue.
- **OEM kill protection.** You can't fully solve this in code. Show a one-time "keep Utify running" screen linking to the OEM's battery settings (dontkillmyapp.com lists them). Check `PowerManager.isIgnoringBatteryOptimizations` and deep-link only when needed. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is restricted on Google Play, but fine for GitHub distribution.

**Expected gain.** Notifications appear on Android 13+, downloads survive backgrounding, and you remove roughly 800+ Firestore writes per playing hour per device.

---

## More issues by area

### Startup, UI and data

- **MEDIUM:** `LibraryNotifier._syncLikesToHive` does `box.clear()` and then `await box.put()` for every liked song each time the likes stream emits. That is N disk writes per like toggle. Use one call: `await box.putAll({for (final s in liked) s.id: s});` and skip it if the id set is unchanged.
- **MEDIUM:** playlists are stored as one Firestore doc with all tracks embedded. The 1 MB doc limit caps you at roughly 3–4k songs per playlist, and every snapshot re-parses every playlist on the UI isolate. `addSongsToPlaylist`, `addSongsToSharedPlaylist` and `copyPlaylistTo` do one Firestore write per song, so a 300-song import means 300 sequential writes. Replace them with a single update using `FieldValue.arrayUnion(songs.map(_songToMap))`. For large libraries, move tracks into a `tracks` subcollection, or at least parse `docChanges` only.
- **MEDIUM:** `FirestoreService.getPublicProfile` always does a network `get()` and a SharedPreferences write. It only falls back to the cache on failure. `friendshipsStream` calls it for every friend on every snapshot (N reads per change). Check `_profileCache` first, with a TTL of about 10 minutes.
- **MEDIUM:** `FriendsScreen._friendTile` creates `FirestoreService().presenceStream(...)` inside `build`. Every rebuild re-subscribes. The desktop panel already uses `friendPresenceProvider(uid)`, so use it here too.
- **MEDIUM:** JSON work on the UI isolate. The InnerTube responses are hundreds of KB and are parsed in `_post`/`_parseSectionList`. `_swr` then runs `jsonEncode` of the whole payload twice per fetch (once in `_store`, once in `YtMusicFeedCache.write`) and a third time in `_readFeedCache` for the fingerprint. Run decode and parse in `Isolate.run`, encode once, and use a hash of the string as the fingerprint.
- **MEDIUM:** `youtube_explode_dart` parses large watch-page and player JSON on the main isolate. Each `getManifest` can stall frames for tens of ms on low-end CPUs. Resolve URLs in a short-lived isolate that returns only strings (`Isolate.run(() async { final yt = YoutubeExplode(); ... yt.close(); return urls; })`).
- **MEDIUM:** side effects in `build`. `SongTile.build` calls `prefetchUrl` for every build of every row, and `prefetchBatch` is also called from search. The prefetch queue is unbounded, so scrolling queues dozens of manifest requests. Call it once in `initState`, only for rows near the top, and cap the queue (say 6) and clear it when the list changes.
- **MEDIUM:** local scan runs on every app resume (`didChangeAppLifecycleState`, plus `initState`), but I couldn't find a mobile screen that displays `localMusicProvider`. It recursively walks Music/Download/etc. with `resolveSymbolicLinksSync` per file. Remove it on mobile, or throttle it (at most once per 30 min) and prefer a MediaStore query.
- **MEDIUM:** `cacheSettingsProvider` is not `autoDispose`. After the settings screen is opened once, a 2 s `Timer.periodic` keeps running `AudioCacheService.stats()` (file I/O for every cached file) plus the feed-cache size scan, forever. Make it `autoDispose` and use a 5–10 s interval.
- **MEDIUM (correctness):** Hive iterates `box.values` and `box.keys` in key order, not insertion order (verify with a 3-line test). `LibraryService.getRecentlyPlayed()` and `addToRecentlyPlayed`'s "evict `keys.first`" therefore work on alphabetical video ids, not recency. Store a `playedAt` field and sort by it. Also, `_clone` drops `isLocal` and `localPath`.
- **MEDIUM (correctness):** optimistic playlist updates create `Playlist(...)` copies (`renamePlaylistObj`, `addSongToPlaylistObj`, `reorderPlaylistSongs` and others). A new instance has no Hive key and no `playlistFirestoreIds` expando entry, so `firestoreId` is null until the next stream emission. In that window `_matchesPlaylist` falls back to name and `createdAt`. Prefer mutating a copy and re-attaching the expando.
- **MINOR:** `AuthGate` initialization is ~8 sequential Firestore round trips (`sync.init`, `getActiveDevice`, `restoreLastSession`, `hasPublicProfile`, ...). Parallelise the independent ones with `Future.wait`.
- **MINOR:** `PlaylistScreen`, `library_screen`, `app.dart` and `ListenPartyControls` create `TextEditingController`s that are never disposed. Wrap them in a `StatefulWidget` dialog or dispose them after `showDialog`.
- **MINOR:** `NowPlayingScreen._showFullLyrics` captures position once, so the sheet doesn't follow playback. It also scans lyric lines linearly each tick, while a binary-search helper already exists.
- **MINOR:** `Song` records persist `streamUrl` (1–2 KB each, expires in 6 h), while an L2 URL cache already exists. Drop the field from persisted copies.

### Memory and storage

- Hive boxes loaded into RAM: see #4.
- Firestore cache cap: see #4.
- Image cache cap: see #2.
- The feed cache (4 MB cap per key, many keys) and the lyrics box have no global size limit. Add a total cap and LRU eviction, or make `clearCache` also run `box.compact()`.
- `MediaStoreHelper` inserts `.mp4` as `video/mp4` into the `MediaStore.Audio` collection. On Android 10+ that MIME mismatch is likely to throw, and your fallback then silently copies the file into app-private documents (verify on an API 29+ device). Use `audio/mp4`, and re-check that downloads actually land in `Music/Utify`.

### Packages

| Package | Issue | Action |
|---|---|---|
| `ffmpeg_kit_flutter_new_audio` | Imported by `ffmpeg_runtime.dart`, but your comments say it's unused for downloads. It adds tens of MB per ABI and, I believe, raises minSdk (to 24 **(verify)**). | Remove it and delete the `platform/ffmpeg_*` files. Keep `convertToMp3` only if you actually use it. |
| `fl_chart` | Only used in `listening_dashboard.dart`, which renders hard-coded mock numbers. | Remove it if the widget isn't shipped. |
| `hive` / `hive_flutter` | Unmaintained for years. | `hive_ce` is a near drop-in. Drift is better if you need queries or indexes. |
| `cloud_firestore` / `firebase_*` | Large, and recent FlutterFire versions require minSdk 23 **(verify in the pubspec lock)**. | If you need Android 5.x (API 21–22), pin an older BoM or drop API 21–22 support. |
| `just_audio_media_kit` | Desktop only, but it sits in the Android dependency graph. | Check that media_kit native libs for Android aren't being bundled. |
| `youtube_explode_dart` | Breaks whenever YouTube changes its player. | Keep it updated and use the isolate approach above. |
| `http`, `dart:io` `HttpClient`, youtube_explode's client | Three HTTP stacks. | Fine, just be aware. |

Also, `playlist_import_service.dart` hard-codes a YouTube Data API key in source, and your repo URL looks public. Restrict that key to YouTube Data API v3 in Google Cloud, rotate it, and ideally move it to `--dart-define`.

### Build and release

```kotlin
// android/app/build.gradle.kts
android {
  defaultConfig {
    ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") } // drop x86_64 for a single universal APK
  }
  buildTypes {
    release {
      isMinifyEnabled = true
      isShrinkResources = true
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
    }
  }
}
```

- Flutter enables R8 for release by default, but be explicit and add keep rules for any plugin that needs them.
- `abiFilters` and `--split-per-abi` conflict. Your updater downloads one `utify-android.apk`, so use `abiFilters` for a single APK. Alternatively upload per-ABI APKs and teach `UpdateService` to pick by ABI (`Build.SUPPORTED_ABIS` via your MethodChannel). That cuts download size about 40% versus a fat APK.
- Build with `flutter build apk --release --obfuscate --split-debug-info=build/symbols --analyze-size`. Icon tree-shaking is on by default.
- **Impeller vs Skia:** Impeller is the default on Android from about Flutter 3.27, but only on devices that support Vulkan (roughly Android 10+), with Skia as the fallback (check your Flutter version's release notes). Android 5–9 phones will therefore be on Skia anyway. To A/B test on a low-end Vulkan device, add `<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false"/>` and compare the raster thread times in DevTools. Don't change the default without numbers.
- `isMinifyEnabled` alone won't remove the ffmpeg libs. Removing the package is the real size win.

### Compatibility

- **Android 13+:** `POST_NOTIFICATIONS`, see #5. Remove `READ_MEDIA_VIDEO`, since you only read audio.
- **Android 14+:** the media-playback FGS type is declared correctly. If you add download FGS, declare its type and permission.
- **Android 10+ scoped storage:** `MANAGE_EXTERNAL_STORAGE` is declared but never requested, so it does nothing except put you on Google Play's restricted-permission list (also true of `REQUEST_INSTALL_PACKAGES`). That matters if you ever publish on Play. For GitHub-only distribution it is less of a problem.
- **Android 6–9:** `network_security_config` is ignored below API 24. `usesCleartextTraffic="true"` plus `<certificates src="user"/>` lets user-installed CAs be trusted for all traffic, which is a MITM risk. Restrict cleartext to localhost, which `LockCachingAudioSource`'s proxy needs, and remove the user trust anchor.
- **Android 5.x:** see the Firebase minSdk note and the ffmpeg note above. Confirm what `flutter.minSdkVersion` resolves to in your Flutter version.
- **Low-end crash risks:** the full-resolution image decoding (#2), RemoteViews bitmaps in the marquee notification (#5), and several Hive boxes in RAM (#4).

---

## Verification checklist (Flutter DevTools, profile mode on a real low-end phone)

Always use `flutter run --profile -d <device>`. Never measure in debug mode or on an emulator.

1. **Startup:** `flutter run --profile --trace-startup` and read `timeToFirstFrameMicros`. Also run `adb shell am start -W -n com.example.testf/.MainActivity` for cold-start time. Compare before and after the Hive, tab and splash changes.
2. **Rebuilds:** in DevTools → Performance, enable "Track widget builds". Play a song on Search and Playlist screens and confirm result rows no longer rebuild every 400 ms. Repeat while a download is running.
3. **Frame timing:** Performance → Frame analysis. Look for frames over 16 ms and check whether they are UI-thread (Dart) or raster. Scroll Search results, Home and a 200-song playlist.
4. **Memory:** Memory tab → take a snapshot, then another after scrolling 100 results. Check `ui.Image` and `ImageCache` size. Use `adb shell dumpsys meminfo com.example.testf` for total PSS, which should stay under about 200 MB on a 2 GB device.
5. **CPU:** CPU profiler while loading Home. Look for `jsonDecode`, `_parseSectionList`, `getManifest` or `jsonEncode` blocks over 30 ms on the UI isolate.
6. **Network and battery:** `adb shell dumpsys batterystats --reset`, play 30 minutes with the screen off, then `adb bugreport` or Battery Historian. Count Firestore writes in the Firebase console before and after the sync change.
7. **Cache behavior:** fill the cache past its limit (set 250 MB) and confirm only the oldest files are evicted, not all of them. Add a log line in `evictIfNeeded` showing `freed` and `total`.
8. **Doze and OEM:** `adb shell dumpsys deviceidle force-idle`, then start a playlist download, lock the phone for 10 minutes, and confirm completion. Repeat on a real Xiaomi, Huawei or Oppo device if you can; emulators won't reproduce their task killers.
9. **Android 13/14 devices:** confirm the notification permission prompt appears, and that the media notification and lock-screen controls work.
10. **Size:** `flutter build apk --release --analyze-size` and review the treemap for ffmpeg, firebase and the ABI breakdown.

---

## Information I need before I can be more precise

1. Your `pubspec.yaml` and `pubspec.lock`. I need the versions of `firebase_core`, `cloud_firestore`, `youtube_explode_dart`, `just_audio`, `audio_service`, `hive` and `ffmpeg_kit_flutter_new_audio`, and whether any media_kit Android libs are bundled.
2. The output of `flutter --version`, and the resolved `minSdkVersion` (`flutter.minSdkVersion` depends on your Flutter version).
3. Why you abandoned audio-only streams. Was it HTTP 403 at download time, or stalls during playback, and on which devices and `youtube_explode_dart` version? That decides the right fix for #3.
4. Is the app distributed only through GitHub releases, or do you plan Google Play? That changes how much the restricted permissions matter.
5. Do you need to support Android 5.x (API 21–22), given recent Firebase minimums?
6. Typical library sizes: songs per playlist, liked songs, number of playlists. That decides whether the single-doc playlist design needs a subcollection now or later.
7. Is `listening_dashboard.dart` shipped, and is local-music scanning meant to be user-visible on mobile?
8. Which low-end devices you test on (model, RAM, Android version), so I can suggest realistic frame-time and memory targets.
