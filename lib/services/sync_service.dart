// ============================================================
// services/sync_service.dart
//
// Simple remote-control sync + active-device ownership.
//
// Active device model (Spotify-style)
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// â€¢ Exactly one device is "active" at a time â€” it owns playback,
//   loads audio, and executes transport commands.
// â€¢ All other devices are "passive" â€” they show the device picker
//   and can send commands (play/pause/next/prev) to the active
//   device via Firestore, but they do NOT load audio.
// â€¢ A passive device becomes active by tapping itself in the
//   device picker (calls claimAsActiveDevice()).
// â€¢ The previous active device becomes passive immediately.
//
// What syncs
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// â€¢ play / pause / next / prev / playSong commands
// â€¢ Queue + current song (so every device shows the same queue)
// â€¢ activeDeviceId (who owns playback right now)
// â€¢ Device name (for the picker list)
//
// What does NOT sync
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// â€¢ Playback position and play state
// â€¢ Volume â€” local only
// ============================================================

import 'dart:async';

import '../models/song.dart';
import 'firestore_service.dart';
import 'device_id_service.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive/hive.dart';

// â”€â”€ Types â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// The command written to Firestore by the acting device.
enum RemoteCommand {
  play,
  pause,
  next,
  prev,
  playSong,
  queueUpdate,
  seek,
  none
}

/// Parsed remote-command document from Firestore.
class RemoteCommandDoc {
  final RemoteCommand command;
  final String deviceId;
  final String deviceName;
  final Song? currentSong;
  final List<Song> queue;
  final int queueIndex;
  final int positionMs;
  final bool isPlaying;

  const RemoteCommandDoc({
    required this.command,
    required this.deviceId,
    required this.deviceName,
    this.currentSong,
    required this.queue,
    required this.queueIndex,
    required this.positionMs,
    required this.isPlaying,
  });

  /// Parse the raw map returned by FirestoreService.
  factory RemoteCommandDoc.fromMap(Map<String, dynamic> m) {
    final cmdStr = m['command'] as String? ?? 'none';
    final command = RemoteCommand.values.firstWhere(
      (c) => c.name == cmdStr,
      orElse: () => RemoteCommand.none,
    );
    return RemoteCommandDoc(
      command: command,
      deviceId: m['deviceId'] as String? ?? '',
      deviceName: m['deviceName'] as String? ?? 'Unknown Device',
      currentSong: m['currentSong'] as Song?,
      queue: (m['queue'] as List?)?.cast<Song>() ?? const [],
      queueIndex: m['queueIndex'] as int? ?? 0,
      positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
      isPlaying: m['isPlaying'] as bool? ?? false,
    );
  }
}

// â”€â”€ Service â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class SyncService {
  final FirestoreService _fs;

  SyncService(this._fs);

  String? _uid;
  String? _deviceId;
  String? _deviceName;

  StreamSubscription? _cmdSub;
  StreamSubscription? _activeDeviceSub;
  Timer? _heartbeatTimer;

  // Broadcast stream of remote commands â€” PlayerNotifier listens.
  final StreamController<RemoteCommandDoc> _cmdController =
      StreamController<RemoteCommandDoc>.broadcast();
  Stream<RemoteCommandDoc> get remoteCommandStream => _cmdController.stream;

  // Broadcast stream of active device changes â€” PlayerNotifier + UI listens.
  final StreamController<ActiveDeviceDoc?> _activeDeviceController =
      StreamController<ActiveDeviceDoc?>.broadcast();
  Stream<ActiveDeviceDoc?> get activeDeviceStream =>
      _activeDeviceController.stream;

  /// Whether this device is currently the active playback device.
  bool _isActive = false;
  bool get isActive => _isActive;
  bool _guestMode = false;

  StreamSubscription? _deviceListSub;
  int _deviceCount = 1;

  /// True when at least one other device is registered in Firestore.
  bool get hasOtherDevices => _deviceCount > 1;

  void setGuestMode(bool enabled) => _guestMode = enabled;

  /// When true, Firestore writes are silently skipped.
  bool _offlineMode = false;

  /// Pause or resume Firestore sync writes.
  /// Pass true when going offline, false on reconnect.
  void setOfflineMode(bool offline) {
    _offlineMode = offline;
    if (offline) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    } else if (_uid != null && _deviceId != null) {
      final platform = _detectPlatform();
      _fs.registerDevice(_uid!, _deviceId!, _deviceName!, platform).catchError((_) {});
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _fs.registerDevice(_uid!, _deviceId!, _deviceName!, platform).catchError((_) {});
      });
    }
  }

  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> init(String uid) async {
    _uid = uid;
    _deviceId = await deviceIdService.getDeviceId();
    _deviceName = await deviceIdService.getDeviceName();
    final platform = _detectPlatform();

    await _fs.registerDevice(uid, _deviceId!, _deviceName!, platform);
    await _fs.removeStaleDevices(uid, keepDeviceId: _deviceId!);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _fs
          .registerDevice(uid, _deviceId!, _deviceName!, platform)
          .catchError((_) {});
    });

    // Subscribe to remote commands.
    _cmdSub?.cancel();
    _cmdSub = _fs.remoteCommandStream(uid).listen(_onRawCmd);

    // Subscribe to active device changes.
    _activeDeviceSub?.cancel();
    _activeDeviceSub = _fs.activeDeviceStream(uid).listen(_onActiveDevice);

    // Subscribe to device list changes to know if other devices are registered.
    _deviceListSub?.cancel();
    _deviceListSub = _fs.devicesStream(uid).listen((devices) {
      _deviceCount = devices.length;
    });

    // Determine initial active state.
    final current = await _fs.getActiveDevice(uid);
    _isActive = current?.deviceId == _deviceId;
    _activeDeviceController.add(current);
  }

  void dispose() {
    _cmdSub?.cancel();
    _cmdSub = null;
    _activeDeviceSub?.cancel();
    _activeDeviceSub = null;
    _deviceListSub?.cancel();
    _deviceListSub = null;
    _deviceCount = 1;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _isActive = false;
    _uid = null;
    _deviceId = null;
    // Do NOT close the broadcast controllers â€” listeners survive logout/re-login.
  }

  void _onRawCmd(Map<String, dynamic>? raw) {
    if (raw == null) return;
    if (_deviceId == null) return;
    final doc = RemoteCommandDoc.fromMap(raw);
    // Ignore commands we sent ourselves.
    if (doc.deviceId == _deviceId) return;
    // Emit to ALL devices (active AND passive).
    // Active device will EXECUTE; passive device will OBSERVE (UI sync only).
    _cmdController.add(doc);
  }

  void _onActiveDevice(ActiveDeviceDoc? doc) {
    _isActive = doc?.deviceId == _deviceId;
    _activeDeviceController.add(doc);
  }

  // â”€â”€ Active device claim â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Make this device the active playback device.
  Future<void> claimAsActiveDevice() async {
    // Treat the initiating device as active immediately. Local playback and
    // its transport controls must remain usable while Firestore completes.
    _isActive = true;
    if (_uid == null || _deviceId == null) return;
    await _fs.claimActiveDevice(_uid!, _deviceId!, _deviceName ?? 'Unknown');
  }

  /// Release this device's active claim (on logout / app close).
  Future<void> releaseIfActive() async {
    if (_uid == null || _deviceId == null) return;
    await _fs.releaseActiveDevice(_uid!, _deviceId!);
    _isActive = false;
  }

  Future<void> unregisterCurrentDevice() async {
    if (_uid == null || _deviceId == null) return;
    await _fs.unregisterDevice(_uid!, _deviceId!);
  }

  /// Transfer active playback to another device by claiming it as active.
  /// This device becomes passive immediately.
  Future<void> transferToDevice(
      String targetDeviceId, String targetDeviceName) async {
    if (_uid == null) return;
    await _fs.claimActiveDevice(_uid!, targetDeviceId, targetDeviceName);
    _isActive = false;
  }

  // â”€â”€ Write API â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> sendCommand({
    required RemoteCommand command,
    required Song? currentSong,
    required List<Song> queue,
    required int queueIndex,
    required int positionMs,
    required bool isPlaying,
  }) async {
    if (_uid == null) {
      if (_guestMode) {
        await _saveGuestPlaybackState(
          currentSong: currentSong,
          queue: queue,
          queueIndex: queueIndex,
          positionMs: positionMs,
          isPlaying: isPlaying,
        );
      }
      return;
    }
    if (_deviceId == null) return;
    await _saveLocalPlaybackState(
      uid: _uid!,
      currentSong: currentSong,
      queue: queue,
      queueIndex: queueIndex,
      positionMs: positionMs,
      isPlaying: isPlaying,
    );
    if (_offlineMode) return; // Offline — skip Firestore write silently.
    await _fs.writeRemoteCommand(
      uid: _uid!,
      deviceId: _deviceId!,
      deviceName: _deviceName ?? 'Unknown',
      command: command.name,
      currentSong: currentSong,
      queue: queue,
      queueIndex: queueIndex,
      positionMs: positionMs,
      isPlaying: isPlaying,
    );
  }

  /// Persist the current queue and track without asking another device to
  /// perform an action. Used during app backgrounding/shutdown.
  Future<void> savePlaybackState({
    required Song? currentSong,
    required List<Song> queue,
    required int queueIndex,
    required int positionMs,
    required bool isPlaying,
  }) {
    return sendCommand(
      command: RemoteCommand.none,
      currentSong: currentSong,
      queue: queue,
      queueIndex: queueIndex,
      positionMs: positionMs,
      isPlaying: isPlaying,
    );
  }

  // â”€â”€ Restore on login â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Returns the last saved queue/song for session restore.
  Future<RemoteCommandDoc?> getLastState() async {
    if (_uid == null) return null;
    final raw = await _fs.getLastRemoteCommand(_uid!);
    if (raw == null) return null;
    return RemoteCommandDoc.fromMap(raw);
  }

  Future<RemoteCommandDoc?> getCachedLastState() async {
    if (_uid == null) return null;
    return getCachedLastStateForUser(_uid!);
  }

  Future<RemoteCommandDoc?> getCachedGuestLastState() async {
    final value = Hive.box('settings').get('guest_playback_state');
    if (value is! Map) return null;
    try {
      return RemoteCommandDoc(
        command: RemoteCommand.none,
        deviceId: '',
        deviceName: 'Guest session',
        currentSong: value['currentSong'] as Song?,
        queue: (value['queue'] as List?)?.whereType<Song>().toList() ?? const [],
        queueIndex: (value['queueIndex'] as num?)?.toInt() ?? 0,
        positionMs: (value['positionMs'] as num?)?.toInt() ?? 0,
        isPlaying: false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveGuestPlaybackState({
    required Song? currentSong,
    required List<Song> queue,
    required int queueIndex,
    required int positionMs,
    required bool isPlaying,
  }) async {
    await Hive.box('settings').put('guest_playback_state', {
      'currentSong': currentSong,
      'queue': List<Song>.from(queue),
      'queueIndex': queueIndex,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
    });
  }

  Future<RemoteCommandDoc?> getCachedLastStateForUser(String uid) async {
    final value = Hive.box('settings').get(_playbackCacheKey(uid));
    if (value is! Map) return null;

    try {
      return RemoteCommandDoc(
        command: RemoteCommand.none,
        deviceId: _deviceId ?? '',
        deviceName: _deviceName ?? 'This device',
        currentSong: value['currentSong'] as Song?,
        queue:
            (value['queue'] as List?)?.whereType<Song>().toList() ?? const [],
        queueIndex: (value['queueIndex'] as num?)?.toInt() ?? 0,
        positionMs: (value['positionMs'] as num?)?.toInt() ?? 0,
        isPlaying: value['isPlaying'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLocalPlaybackState({
    required String uid,
    required Song? currentSong,
    required List<Song> queue,
    required int queueIndex,
    required int positionMs,
    required bool isPlaying,
  }) async {
    await Hive.box('settings').put(_playbackCacheKey(uid), {
      'currentSong': currentSong,
      'queue': List<Song>.from(queue),
      'queueIndex': queueIndex,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
    });
  }

  String _playbackCacheKey(String uid) => 'playback_state_$uid';

  // â”€â”€ Device list stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Stream<List<DeviceInfo>> devicesStream() {
    if (_uid == null) return const Stream.empty();
    return _fs.devicesStream(_uid!);
  }

  // â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  String _detectPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}

