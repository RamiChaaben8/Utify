// ============================================================
// providers/update_provider.dart
//
// Riverpod state for the update flow.
//
// UpdateNotifier drives the entire check → download → install
// lifecycle.  The UI just watches UpdateState and calls methods
// on the notifier — no business logic in widgets.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';

// ── State ────────────────────────────────────────────────────────────────────

enum UpdateStatus {
  idle,         // nothing happening
  checking,     // calling GitHub API
  available,    // update found, waiting for user action
  upToDate,     // checked — already on latest
  downloading,  // fetching the asset
  installing,   // installer handed off (Android package installer / Windows Setup)
  error,        // something went wrong
}

class UpdateState {
  final UpdateStatus status;
  final UpdateResult? result;
  final double downloadProgress; // 0.0 – 1.0
  final String? errorMessage;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.result,
    this.downloadProgress = 0.0,
    this.errorMessage,
  });

  UpdateState copyWith({
    UpdateStatus? status,
    UpdateResult? result,
    double? downloadProgress,
    String? errorMessage,
    bool clearError = false,
    bool clearResult = false,
  }) {
    return UpdateState(
      status: status ?? this.status,
      result: clearResult ? null : (result ?? this.result),
      downloadProgress: downloadProgress ?? this.downloadProgress,
      errorMessage:
          clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ── Notifier ─────────────────────────────────────────────────────────────────

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier() : super(const UpdateState());

  /// Check GitHub for a newer release.
  Future<void> checkForUpdate() async {
    if (state.status == UpdateStatus.checking) return; // debounce

    state = state.copyWith(
      status: UpdateStatus.checking,
      clearError: true,
      clearResult: true,
      downloadProgress: 0.0,
    );

    try {
      final result = await updateService.checkForUpdate();
      state = state.copyWith(
        status: result.updateAvailable
            ? UpdateStatus.available
            : UpdateStatus.upToDate,
        result: result,
      );
    } on UpdateException catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'An unexpected error occurred: $e',
      );
    }
  }

  /// Download and install the update.
  /// [onUnsupported] is called (instead of throwing) when the platform
  /// is macOS or Linux — the UI shows a "download manually" message.
  Future<void> downloadAndInstall({
    required void Function(String releasePageUrl) onUnsupported,
  }) async {
    final result = state.result;
    if (result == null) return;

    state = state.copyWith(
      status: UpdateStatus.downloading,
      downloadProgress: 0.0,
      clearError: true,
    );

    try {
      await updateService.downloadAndInstallUpdate(
        result,
        onProgress: (p) {
          // Guard: only update while still downloading.
          if (state.status == UpdateStatus.downloading) {
            state = state.copyWith(downloadProgress: p);
          }
        },
        onInstalling: () {
          // Windows: Setup is running and Utify is about to close, so the
          // future above never completes — flip the UI state here instead.
          if (state.status == UpdateStatus.downloading) {
            state = state.copyWith(status: UpdateStatus.installing);
          }
        },
      );
      if (state.status == UpdateStatus.downloading) {
        state = state.copyWith(status: UpdateStatus.installing);
      }
      // If we get here on Windows the app should already be exiting.
      // This line is only reached if exit(0) somehow didn't fire.
    } on UnimplementedError catch (e) {
      // macOS / Linux — platform not yet supported.
      state = state.copyWith(
        status: UpdateStatus.available, // go back to "available" so UI still shows
        downloadProgress: 0.0,
      );
      onUnsupported(result.releasePage);
    } on UpdateException catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: e.message,
        downloadProgress: 0.0,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Install failed: $e',
        downloadProgress: 0.0,
      );
    }
  }

  /// Reset back to idle (e.g. after dismissing the dialog).
  void reset() => state = const UpdateState();
}

// ── Provider ──────────────────────────────────────────────────────────────────

final updateProvider =
    StateNotifierProvider<UpdateNotifier, UpdateState>((_) => UpdateNotifier());
