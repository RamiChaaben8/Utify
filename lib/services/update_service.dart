// ============================================================
// services/update_service.dart
//
// In-app update service — desktop only.
//
// checkForUpdate()
//   Hits the GitHub Releases API, parses the latest tag, and
//   does a semver comparison against the running app version.
//   Returns an UpdateResult with all info needed by the UI.
//
// downloadAndInstallUpdate()
//   WINDOWS  — fully implemented: downloads the zip to a temp
//              directory, extracts it, and launches the bundled
//              updater script, then exits the app.
//   macOS    — STUB: throws UnimplementedError. See TODO below.
//   Linux    — STUB: throws UnimplementedError. See TODO below.
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'app_constants.dart';

// ── Result types ─────────────────────────────────────────────────────────────

class UpdateResult {
  final bool updateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;
  final String releasePage;

  const UpdateResult({
    required this.updateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.releasePage,
  });

  /// Convenience: no update available (same version).
  factory UpdateResult.upToDate(String version) => UpdateResult(
        updateAvailable: false,
        currentVersion: version,
        latestVersion: version,
        downloadUrl: '',
        releaseNotes: '',
        releasePage: AppConstants.githubReleasesPageUrl,
      );
}

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => 'UpdateException: $message';
}

// ── Service ──────────────────────────────────────────────────────────────────

class UpdateService {
  static const MethodChannel _androidUpdateChannel =
      MethodChannel('com.example.testf/app_update');
  // Shared HTTP client — reuse across calls.
  static final http.Client _client = http.Client();

  // ── Check for update ────────────────────────────────────────────────────

  /// Fetches the latest GitHub release and compares with the current version.
  ///
  /// Throws [UpdateException] on network failures, rate limits, or if the
  /// response is malformed.
  Future<UpdateResult> checkForUpdate() async {
    final info = await PackageInfo.fromPlatform();

    // PackageInfo.version can include a build-metadata suffix from pubspec
    // (e.g. "1.0.0+1").  Strip everything from '+' onwards so we compare
    // pure semver triplets against the GitHub tag.
    final currentVersion = info.version.split('+').first.trim();

    http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(AppConstants.githubReleasesApiUrl),
            headers: {
              'Accept': 'application/vnd.github.v3+json',
              'User-Agent': 'Utify/${info.version}',
            },
          )
          .timeout(const Duration(seconds: 15));
    } on SocketException {
      throw const UpdateException(
          'No internet connection. Check your network and try again.');
    } on HttpException catch (e) {
      throw UpdateException('Network error: ${e.message}');
    } catch (e) {
      throw UpdateException('Failed to contact GitHub: $e');
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateException(
          'GitHub API rate limit reached. Please try again in a few minutes.');
    }
    if (response.statusCode == 404) {
      throw const UpdateException(
          'No releases found for this repository yet.');
    }
    if (response.statusCode != 200) {
      throw UpdateException(
          'GitHub returned an unexpected status: ${response.statusCode}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const UpdateException('Could not parse the GitHub release data.');
    }

    final tagName = json['tag_name'] as String?;
    if (tagName == null || tagName.isEmpty) {
      throw const UpdateException('GitHub release is missing a version tag.');
    }

    // Strip leading 'v' or 'V' so we can compare purely numeric semver strings.
    final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');

    final assets = (json['assets'] as List<dynamic>?) ?? [];
    final releaseNotes =
        (json['body'] as String?)?.trim() ?? 'No release notes available.';
    final releasePage = (json['html_url'] as String?) ??
        AppConstants.githubReleasesPageUrl;

    // Pick the asset for the current platform. Android releases contain
    // split APKs; arm64 is the safest default for modern phones.
    final asset = await _selectAsset(assets);

    final downloadUrl =
        (asset?['browser_download_url'] as String?) ?? '';

    final updateAvailable = _isNewer(latestVersion, currentVersion);

    return UpdateResult(
      updateAvailable: updateAvailable,
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      downloadUrl: downloadUrl,
      releaseNotes: releaseNotes,
      releasePage: releasePage,
    );
  }

  // ── Download and install ─────────────────────────────────────────────────

  /// Downloads the release asset and installs it.
  ///
  /// [onProgress] is called with values 0.0–1.0 as the download progresses.
  ///
  /// WINDOWS: fully implemented.
  /// macOS / Linux: stubs — throw [UnimplementedError] with helpful messages.
  Future<void> downloadAndInstallUpdate(
    UpdateResult result, {
    ValueChanged<double>? onProgress,
  }) async {
    if (Platform.isWindows) {
      return _installWindows(result, onProgress: onProgress);
    } else if (Platform.isAndroid) {
      return _installAndroid(result, onProgress: onProgress);
    } else if (Platform.isMacOS) {
      return _installMacOS(result);
    } else if (Platform.isLinux) {
      return _installLinux(result);
    } else {
      throw UpdateException(
          'Auto-update is not supported on this platform.');
    }
  }

  Future<void> _installAndroid(
    UpdateResult result, {
    ValueChanged<double>? onProgress,
  }) async {
    if (result.downloadUrl.isEmpty) {
      throw UpdateException('No Android APK found in this release. Please visit ${result.releasePage}.');
    }
    final dir = await getTemporaryDirectory();
    final apk = File('${dir.path}${Platform.pathSeparator}utify-update.apk');
    try {
      final response = await _client.send(http.Request('GET', Uri.parse(result.downloadUrl)))
          .timeout(const Duration(minutes: 10));
      if (response.statusCode != 200) {
        throw UpdateException('APK download failed (HTTP ${response.statusCode}).');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = apk.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } on SocketException {
      throw const UpdateException('Download interrupted. Check your internet connection.');
    } catch (e) {
      if (e is UpdateException) rethrow;
      throw UpdateException('APK download failed: $e');
    }
    if (await apk.length() < 1024 * 1024) {
      throw const UpdateException('Downloaded APK appears incomplete. Please try again.');
    }
    onProgress?.call(1.0);
    final launched = await _androidUpdateChannel.invokeMethod<bool>('installApk', {'path': apk.path});
    if (launched != true) {
      throw const UpdateException('Allow Utify to install unknown apps in Android Settings, then tap Update Now again.');
    }
  }

  // ── Windows implementation ───────────────────────────────────────────────

  Future<void> _installWindows(
    UpdateResult result, {
    ValueChanged<double>? onProgress,
  }) async {
    if (result.downloadUrl.isEmpty) {
      throw UpdateException(
          'No Windows installer found in this release. '
          'Please visit ${result.releasePage} to download manually.');
    }

    // 1. Download the installer .exe to a temp directory.
    final tempDir = await getTemporaryDirectory();
    final installerPath = '${tempDir.path}\\utify-setup.exe';
    final installerFile = File(installerPath);
    int? expectedSize;
    bool hasContentEncoding = false;

    try {
      final req = http.Request('GET', Uri.parse(result.downloadUrl));
      final streamedResponse = await _client.send(req).timeout(
        const Duration(minutes: 10),
      );

      if (streamedResponse.statusCode != 200) {
        throw UpdateException(
            'Download failed (HTTP ${streamedResponse.statusCode}).');
      }

      expectedSize = streamedResponse.contentLength;
      hasContentEncoding =
          streamedResponse.headers['content-encoding']?.isNotEmpty ?? false;
      final total = expectedSize ?? 0;
      var received = 0;

      final sink = installerFile.openWrite();
      await for (final chunk in streamedResponse.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } on SocketException {
      throw const UpdateException(
          'Download interrupted. Check your internet connection.');
    } catch (e) {
      if (e is UpdateException) rethrow;
      throw UpdateException('Download failed: $e');
    }

    // 2. Verify the file was fully downloaded.
    final downloadedSize = await installerFile.length();
    if (downloadedSize < 1024 * 100) {
      // Less than 100 KB is definitely corrupt for a Flutter app installer
      throw const UpdateException(
          'Downloaded installer appears corrupt (too small). Please try again.');
    }
    if (!hasContentEncoding &&
        expectedSize != null &&
        downloadedSize != expectedSize) {
      throw UpdateException(
          'Downloaded installer is incomplete '
          '($downloadedSize of $expectedSize bytes).');
    }

    onProgress?.call(1.0);

    // 3. Start Setup before exiting. Inno Setup handles closing the app
    // and relaunches Utify through the installer's [Run] entry.
    final logPath = '${tempDir.path}\\utify-setup.log';
    try {
      await Process.start(
        installerPath,
        [
          '/SILENT',
          '/CLOSEAPPLICATIONS',
          '/NORESTART',
          '/LOG="$logPath"',
        ],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
    } catch (error, stack) {
      debugPrint('[Update] Failed to launch installer: $error');
      debugPrint('[Update] Stack: $stack');
      throw UpdateException(
          'The update was downloaded, but the installer could not be started: $error');
    }
    exit(0);
  }

  // ── macOS stub ───────────────────────────────────────────────────────────

  // TODO(macOS): Implement macOS auto-update.
  //
  // Recommended approach: use the `auto_updater` Flutter package
  // (https://pub.dev/packages/auto_updater) which wraps the native
  // Sparkle framework. Steps:
  //   1. Add auto_updater to pubspec.yaml.
  //   2. Publish an appcast XML feed (hosted on GitHub Pages or in the
  //      release assets).
  //   3. Call autoUpdater.setFeedURL(feedUrl) on app startup.
  //   4. Call autoUpdater.checkForUpdates() here.
  //
  // Alternative (manual .app replacement):
  //   1. Download the .zip containing the new .app bundle.
  //   2. Mount the DMG or unzip to a temp dir.
  //   3. Use Process.run('cp', ['-R', newApp, currentApp]) to replace.
  //   4. Re-launch the new .app and exit.
  //   Note: Gatekeeper and SIP may block this — Sparkle handles it correctly.
  Future<void> _installMacOS(UpdateResult result) async {
    throw UnimplementedError(
      'macOS auto-update is not yet implemented. '
      'Please download the latest version from: ${result.releasePage}',
    );
  }

  // ── Linux stub ───────────────────────────────────────────────────────────

  // TODO(Linux): Implement Linux auto-update.
  //
  // Recommended approaches:
  //
  // Option A — AppImage self-replace:
  //   If the app is distributed as an AppImage, download the new .AppImage,
  //   make it executable (chmod +x), replace the current file, and re-launch.
  //   The current AppImage path is available via Platform.resolvedExecutable.
  //
  // Option B — tar.gz swap:
  //   1. Download the tar.gz release asset.
  //   2. Extract to a temp dir using Process.run('tar', ['-xzf', ...]).
  //   3. Copy the new binary over the existing one.
  //   4. Re-launch via Process.start and exit(0).
  //   Note: requires write permission to the install directory — typically
  //   fine for per-user ~/bin installs, not for /usr/bin.
  //
  // Option C — Package manager hook:
  //   If distributing via apt/pacman/flatpak, it may be cleaner to just open
  //   the release page and let the user update via their package manager.
  Future<void> _installLinux(UpdateResult result) async {
    throw UnimplementedError(
      'Linux auto-update is not yet implemented. '
      'Please download the latest version from: ${result.releasePage}',
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Returns the platform-specific release asset filename.
  Future<Map<String, dynamic>?> _selectAsset(List<dynamic> assets) async {
    final names = <String>[
      if (Platform.isAndroid) ...await _androidAssetNames(),
      if (Platform.isWindows) AppConstants.windowsAssetName,
      if (Platform.isMacOS) AppConstants.macosAssetName,
      if (Platform.isLinux) AppConstants.linuxAssetName,
    ];

    for (final name in names) {
      for (final rawAsset in assets) {
        final asset = rawAsset as Map<String, dynamic>;
        if (asset['name'] == name) return asset;
      }
    }
    return null;
  }

  Future<List<String>> _androidAssetNames() async {
    const assetByAbi = <String, String>{
      'arm64-v8a': 'app-arm64-v8a-release.apk',
      'armeabi-v7a': 'app-armeabi-v7a-release.apk',
      'x86_64': 'app-x86_64-release.apk',
    };
    try {
      final supportedAbis = await _androidUpdateChannel
          .invokeListMethod<String>('getSupportedAbis');
      final names = <String>[];
      for (final abi in supportedAbis ?? const <String>[]) {
        final assetName = assetByAbi[abi];
        if (assetName != null && !names.contains(assetName)) {
          names.add(assetName);
        }
      }
      if (names.isNotEmpty) return names;
    } catch (error) {
      debugPrint('[Update] Could not determine Android ABIs: $error');
    }
    return const [
      'app-arm64-v8a-release.apk',
      'app-armeabi-v7a-release.apk',
      'app-x86_64-release.apk',
    ];
  }

  /// Returns true if [latest] is strictly newer than [current].
  /// Both should be clean semver strings like "1.2.3".
  bool _isNewer(String latest, String current) {
    try {
      final l = _parseSemver(latest);
      final c = _parseSemver(current);
      for (var i = 0; i < 3; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
      }
      return false; // equal
    } catch (_) {
      // If parsing fails, do a simple string comparison as fallback.
      return latest != current;
    }
  }

  List<int> _parseSemver(String v) {
    // Strip build metadata (+anything) and pre-release labels (-anything)
    // before splitting so "1.0.0+1" and "1.0.0-beta" both parse cleanly.
    final clean = v.split('+').first.split('-').first.trim();
    final parts = clean.split('.').map((p) => int.parse(p.trim())).toList();
    while (parts.length < 3) parts.add(0);
    return parts;
  }
}

// ── Singleton accessor ────────────────────────────────────────────────────────

final updateService = UpdateService();
