// ============================================================
// widgets/device_picker.dart
//
// Spotify-style device picker.
//
// DevicePickerButton — cast icon in the player bar/mini-player.
//   Painted in the active theme's accent colour in every state.
//
// DevicePickerSheet — bottom sheet listing all devices.
//   Tap "Listen here" to claim this device as active.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/player_provider.dart';
import '../providers/sync_provider.dart';
import '../services/firestore_service.dart';
import '../desktop/theme/desktop_theme.dart';

// ── Button ────────────────────────────────────────────────────────────────────

class DevicePickerButton extends ConsumerWidget {
  /// Size of the icon. Defaults to 20.
  final double size;

  /// Glyph to show. Defaults to a cast icon; the Verdant Night player bar
  /// passes a device glyph instead.
  final IconData icon;

  const DevicePickerButton({
    super.key,
    this.size = 20,
    this.icon = Icons.cast,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = ref.watch(playerProvider.select((s) => s.isActiveDevice));
    final theme = AppThemeScope.maybeOf(context);
    // Painted in the active theme's accent colour in every state — the control
    // should read green/red/lime, never white or grey.
    final color = theme?.nowPlayingAccent ?? const Color(0xFF1DB954);

    return IconButton(
      icon: Icon(icon, color: color, size: size),
      tooltip: isActive ? 'Listening here' : 'Playing on another device',
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(minWidth: size + 16, minHeight: size + 16),
      onPressed: () => _openPicker(context, ref),
    );
  }

  void _openPicker(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context);
    showModalBottomSheet(
      context: context,
      // panelColor, not main: under Verdant Night `main` is byte-identical to
      // the shell background, so the sheet had no surface of its own.
      backgroundColor:
          AppThemeScope.maybeOf(context)?.panelColor ?? const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: const DevicePickerSheet(),
      ),
    );
  }
}

// ── Sheet ─────────────────────────────────────────────────────────────────────

class DevicePickerSheet extends ConsumerWidget {
  const DevicePickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = AppThemeScope.maybeOf(context);
    final playerState = ref.watch(playerProvider);
    final activeDevice = playerState.activeDevice;
    final isThisDeviceActive = playerState.isActiveDevice;
    final myDeviceId = ref.read(syncProvider.notifier).service.deviceId;

    final devicesAsync = ref.watch(_devicesStreamProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Handle ────────────────────────────────────────────────────
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme?.shadow ?? const Color(0xFF4A4A4A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Title ─────────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Connect to a device',
                style: TextStyle(
                  color: theme?.text ?? Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 4),

            if (!isThisDeviceActive && activeDevice != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Playing on ${activeDevice.deviceName}',
                  style: TextStyle(
                    color: theme?.nowPlayingAccent ?? const Color(0xFF1DB954),
                    fontSize: 13,
                  ),
                ),
              ),

            const SizedBox(height: 12),

            // ── Device list ───────────────────────────────────────────────
            devicesAsync.when(
              loading: () => Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: CircularProgressIndicator(
                        color: theme?.button ?? const Color(0xFF1DB954),
                        strokeWidth: 2)),
              ),
              error: (_, __) => Padding(
                padding: EdgeInsets.all(24),
                child: Text('Could not load devices',
                    style: TextStyle(
                        color: theme?.subtext ?? const Color(0xFFB3B3B3))),
              ),
              data: (devices) {
                if (devices.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No devices found',
                        style: TextStyle(
                            color: theme?.subtext ?? const Color(0xFFB3B3B3))),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: devices.length,
                  itemBuilder: (context, i) {
                    final device = devices[i];
                    final isThisDevice = device.deviceId == myDeviceId;
                    final isCurrentlyActive =
                        device.deviceId == activeDevice?.deviceId;

                    return _DeviceTile(
                      device: device,
                      isThisDevice: isThisDevice,
                      isActive: isCurrentlyActive,
                      onTap: isCurrentlyActive
                          ? null // already active, nothing to do
                          : isThisDevice
                              ? () async {
                                  await ref
                                      .read(playerProvider.notifier)
                                      .listenHere();
                                  if (context.mounted) Navigator.pop(context);
                                }
                              : () async {
                                  // Transfer playback to another same-account device.
                                  await ref
                                      .read(playerProvider.notifier)
                                      .transferToDevice(
                                          device.deviceId, device.name);
                                  if (context.mounted) Navigator.pop(context);
                                },
                    );
                  },
                );
              },
            ),

            const SizedBox(height: 8),

            // ── "Listen here" button — shown when this device is passive ──
            if (!isThisDeviceActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme?.button ?? const Color(0xFF1DB954),
                      foregroundColor: theme?.onButtonFill ?? Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(32)),
                    ),
                    icon: const Icon(Icons.headphones, size: 20),
                    label: const Text(
                      'Listen on this device',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    onPressed: () async {
                      await ref.read(playerProvider.notifier).listenHere();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              )
            else
              const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ── Device tile ───────────────────────────────────────────────────────────────

class _DeviceTile extends StatelessWidget {
  final DeviceInfo device;
  final bool isThisDevice;
  final bool isActive;
  final VoidCallback? onTap;

  const _DeviceTile({
    required this.device,
    required this.isThisDevice,
    required this.isActive,
    required this.onTap,
  });

  IconData _iconFor(String platform) {
    switch (platform) {
      case 'android':
      case 'ios':
        return Icons.smartphone;
      case 'windows':
      case 'linux':
      case 'macos':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppThemeScope.maybeOf(context);
    final nameStyle = TextStyle(
      color: isActive
          ? theme?.nowPlayingAccent ?? const Color(0xFF1DB954)
          : theme?.text ?? Colors.white,
      fontSize: 15,
      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
    );

    return ListTile(
      leading: Icon(
        _iconFor(device.platform),
        color: isActive
            ? theme?.nowPlayingAccent ?? const Color(0xFF1DB954)
            : theme?.iconDefault ?? const Color(0xFFB3B3B3),
        size: 28,
      ),
      title: Text(
        isThisDevice ? '${device.name} (this device)' : device.name,
        style: nameStyle,
      ),
      subtitle: isActive
          ? Text('Now playing',
              style: TextStyle(
                  color: theme?.nowPlayingAccent ?? const Color(0xFF1DB954),
                  fontSize: 12))
          // `shadow` is the divider/border token — at 12px on the sheet
          // background it was effectively invisible in every theme.
          : (isThisDevice
              ? Text('Tap to listen here',
                  style: TextStyle(
                      color: theme?.subtext ?? const Color(0xFFB3B3B3),
                      fontSize: 12))
              : Text('Tap to transfer here',
                  style: TextStyle(
                      color: theme?.subtext ?? const Color(0xFFB3B3B3),
                      fontSize: 12))),
      trailing: isActive
          ? Icon(Icons.volume_up,
              color: theme?.nowPlayingAccent ?? const Color(0xFF1DB954),
              size: 20)
          : null,
      onTap: onTap,
    );
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final _devicesStreamProvider = StreamProvider<List<DeviceInfo>>((ref) {
  return ref.watch(syncProvider.notifier).service.devicesStream();
});
