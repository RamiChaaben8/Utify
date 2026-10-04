// ============================================================
// widgets/offline_indicator.dart
//
// A small banner that appears when the device has no real
// internet access. Driven by ConnectivityNotifier (which does
// an actual HTTP reachability probe) and the manual offline
// mode toggle.
//
// Wire this into the app shell as a Positioned top banner
// (similar to RemotePlaybackBanner).
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../desktop/theme/desktop_theme.dart';
import '../providers/connectivity_provider.dart';

// ── Legacy shim — kept so existing usages of offlineProvider
// in other files don't break until they are migrated.
final offlineProvider = Provider<bool>((ref) {
  return !ref.watch(isOnlineProvider);
});

// ── Widget ────────────────────────────────────────────────────────────────────

class OfflineIndicator extends ConsumerWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivity = ref.watch(connectivityProvider);
    final isOffline = !connectivity.isOnline || connectivity.offlineModeEnabled;
    if (!isOffline) return const SizedBox.shrink();

    final theme = AppThemeScope.maybeOf(context);
    final warning = theme?.warning ?? Colors.orange;
    final label = connectivity.offlineModeEnabled && connectivity.isOnline
        ? 'Offline mode — tap to go online'
        : 'Offline — changes will sync when reconnected';

    return Material(
      color: theme?.main.withValues(alpha: 0) ?? Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: warning.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: warning.withValues(alpha: 0.4)),
        ),
        child: GestureDetector(
          onTap: connectivity.offlineModeEnabled
              ? () => ref
                  .read(connectivityProvider.notifier)
                  .setOfflineMode(false)
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, color: warning, size: 16),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(color: warning, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
