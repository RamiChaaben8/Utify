// ============================================================
// providers/connectivity_provider.dart
//
// Real internet reachability — not just "wifi connected".
//
// connectivity_plus tells us the link type, but it can report
// "wifi" while behind a captive portal with no internet.
// We add a lightweight HEAD request to verify actual reachability.
//
// Offline mode
// ─────────────────────────────────────────────────────────────
// A manual "Offline mode" toggle in settings forces offline
// behaviour even when the network is available.  When toggled
// on, isOnline reports false and the app behaves as if there
// is no network.
//
// The stream [connectivityStream] emits a bool on every change.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

const String _kOfflineModeKey = 'offline_mode_enabled';

// ── Reachability probe ────────────────────────────────────────────────────────

/// Attempts a HEAD request to a reliable endpoint.
/// Returns true if we get any HTTP response (even 4xx), meaning internet works.
Future<bool> _probeInternet() async {
  // Try two probes in parallel — if either succeeds we are online.
  const probes = [
    'https://www.google.com',
    'https://connectivitycheck.gstatic.com/generate_204',
  ];
  final futures = probes.map((url) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout       = const Duration(seconds: 5);
      final request  = await client.headUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain<void>();
      client.close();
      return true;
    } catch (_) {
      return false;
    }
  });

  final results = await Future.wait(futures);
  return results.any((r) => r);
}

// ── State ─────────────────────────────────────────────────────────────────────

class ConnectivityState {
  /// True when there is real internet and offline mode is off.
  final bool isOnline;

  /// True when the user has manually enabled offline mode.
  final bool offlineModeEnabled;

  const ConnectivityState({
    this.isOnline          = true,
    this.offlineModeEnabled = false,
  });

  ConnectivityState copyWith({bool? isOnline, bool? offlineModeEnabled}) {
    return ConnectivityState(
      isOnline:           isOnline           ?? this.isOnline,
      offlineModeEnabled: offlineModeEnabled ?? this.offlineModeEnabled,
    );
  }
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class ConnectivityNotifier extends StateNotifier<ConnectivityState> {
  final _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _probeDebounce;

  ConnectivityNotifier() : super(const ConnectivityState()) {
    _loadOfflineMode();
    _sub = _connectivity.onConnectivityChanged.listen(_onLinkChanged);
    // Initial probe.
    _scheduleProbe(immediately: true);
  }

  void _loadOfflineMode() {
    try {
      final box = Hive.box('settings');
      final stored = box.get(_kOfflineModeKey) as bool? ?? false;
      state = state.copyWith(offlineModeEnabled: stored);
    } catch (_) {}
  }

  void _onLinkChanged(List<ConnectivityResult> results) {
    // Link changed — re-probe after a short settle delay.
    _scheduleProbe();
  }

  void _scheduleProbe({bool immediately = false}) {
    _probeDebounce?.cancel();
    _probeDebounce = Timer(
      immediately ? Duration.zero : const Duration(seconds: 2),
      _probe,
    );
  }

  Future<void> _probe() async {
    if (state.offlineModeEnabled) {
      if (mounted) state = state.copyWith(isOnline: false);
      return;
    }
    try {
      final result = await _probeInternet();
      if (mounted) {
        state = state.copyWith(isOnline: result);
        if (kDebugMode) {
          debugPrint('[Connectivity] isOnline=$result');
        }
      }
    } catch (e) {
      if (mounted) state = state.copyWith(isOnline: false);
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> setOfflineMode(bool enabled) async {
    try {
      await Hive.box('settings').put(_kOfflineModeKey, enabled);
    } catch (_) {}
    if (mounted) {
      state = state.copyWith(
        offlineModeEnabled: enabled,
        isOnline: enabled ? false : state.isOnline,
      );
    }
    if (!enabled) {
      // Re-probe immediately when coming back online.
      _scheduleProbe(immediately: true);
    }
  }

  /// Force an immediate reachability re-check.
  Future<void> refresh() => _probe();

  @override
  void dispose() {
    _probeDebounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final connectivityProvider =
    StateNotifierProvider<ConnectivityNotifier, ConnectivityState>((ref) {
  return ConnectivityNotifier();
});

/// Convenience selector — true if the device has real internet and offline
/// mode is off.
final isOnlineProvider = Provider<bool>((ref) {
  return ref.watch(connectivityProvider).isOnline;
});
