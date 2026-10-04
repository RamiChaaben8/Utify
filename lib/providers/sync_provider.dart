// ============================================================
// providers/sync_provider.dart
//
// Riverpod provider wrapping SyncService.
// AuthGate calls syncProvider.notifier.init(uid) after login.
// PlayerProvider calls it for throttled/immediate writes.
// App lifecycle observer calls it for background flush.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sync_service.dart';
import '../services/firestore_service.dart';

final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  return FirestoreService();
});

class SyncNotifier extends StateNotifier<SyncState> {
  final SyncService _service;

  SyncNotifier(this._service) : super(const SyncState());

  SyncService get service => _service;

  Future<void> init(String uid) async {
    await _service.init(uid);
    state = state.copyWith(uid: uid, initialised: true);
  }

  /// Suspend or resume Firestore sync writes based on connectivity.
  void setOfflineMode(bool offline) => _service.setOfflineMode(offline);

  /// Re-subscribe to Firestore after coming back online.
  /// If [isActivelyPlaying] is true this device publishes its current state;
  /// otherwise remote state wins for queue/position.
  Future<void> reconnect({required bool isActivelyPlaying}) async {
    final uid = state.uid;
    if (uid == null) return;
    _service.setOfflineMode(false);
    // Re-run init to refresh Firestore subscriptions.
    await _service.init(uid);
    state = state.copyWith(initialised: true);
  }

  void reset() {
    _service.dispose();
    state = const SyncState();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}

class SyncState {
  final String? uid;
  final bool initialised;

  const SyncState({this.uid, this.initialised = false});

  SyncState copyWith({String? uid, bool? initialised}) {
    return SyncState(
      uid: uid ?? this.uid,
      initialised: initialised ?? this.initialised,
    );
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final fs = ref.watch(firestoreServiceProvider);
  final syncService = SyncService(fs);

  final notifier = SyncNotifier(syncService);

  // When the user signs out, reset the sync state
  ref.onDispose(() => notifier.reset());

  return notifier;
});
