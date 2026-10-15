// ============================================================
// widgets/update_dialog.dart
//
// Reusable dialog that covers the full update flow:
//
//   checking   → spinner
//   upToDate   → "You're up to date" message
//   available  → version info + release notes + action buttons
//               (Windows: "Update Now" | macOS/Linux: "Download")
//   downloading→ progress bar
//   error      → error message + retry button
//
// Usage:
//   showUpdateDialog(context, ref);
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

import '../desktop/theme/app_theme.dart';
import '../desktop/theme/desktop_theme.dart';
import '../providers/update_provider.dart';
import '../services/app_constants.dart';

/// Opens the update dialog.  Call from any desktop UI entry-point.
Future<void> showUpdateDialog(BuildContext context, WidgetRef ref) {
  // Kick off the check immediately when the dialog opens.
  ref.read(updateProvider.notifier).checkForUpdate();

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _UpdateDialogShell(),
  );
}

// ── Shell (provides its own ProviderScope read access) ────────────────────────

class _UpdateDialogShell extends ConsumerWidget {
  const _UpdateDialogShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateProvider);
    final theme = context.appTheme;

    return AlertDialog(
      backgroundColor: theme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Row(
        children: [
          Icon(Icons.system_update_alt,
              color: theme.nowPlayingAccent, size: 22),
          const SizedBox(width: 10),
          Text(
            'Check for Updates',
            style: TextStyle(color: theme.text, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: _UpdateDialogBody(state: state),
      ),
      actions: _buildActions(context, ref, state, theme),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    WidgetRef ref,
    UpdateState state,
    AppThemeData theme,
  ) {
    final notifier = ref.read(updateProvider.notifier);

    switch (state.status) {
      case UpdateStatus.idle:
      case UpdateStatus.checking:
        return [_cancelBtn(context, ref, theme)];

      case UpdateStatus.upToDate:
        return [
          TextButton(
            onPressed: () {
              notifier.reset();
              Navigator.of(context).pop();
            },
            child: Text('Close', style: TextStyle(color: theme.button)),
          ),
        ];

      case UpdateStatus.available:
        final isUnsupportedPlatform = !Platform.isWindows && !Platform.isAndroid;
        return [
          _cancelBtn(context, ref, theme),
          const SizedBox(width: 4),
          if (isUnsupportedPlatform)
            // Open the release page in the browser instead of crashing.
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.button,
                foregroundColor: theme.onButtonFill,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Download from GitHub'),
              onPressed: () async {
                final url =
                    Uri.parse(state.result?.releasePage ??
                        AppConstants.githubReleasesPageUrl);
                await launchUrl(url, mode: LaunchMode.externalApplication);
              },
            )
          else
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.button,
                foregroundColor: theme.onButtonFill,
              ),
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(Platform.isAndroid ? 'Download & Install' : 'Update Now'),
              onPressed: () => notifier.downloadAndInstall(
                onUnsupported: (releasePageUrl) async {
                  final url = Uri.parse(releasePageUrl);
                  await launchUrl(url,
                      mode: LaunchMode.externalApplication);
                },
              ),
            ),
        ];

      case UpdateStatus.downloading:
        return [_cancelBtn(context, ref, theme, disabled: true)];

      case UpdateStatus.installing:
        return [TextButton(
          onPressed: () { notifier.reset(); Navigator.of(context).pop(); },
          child: Text('Close', style: TextStyle(color: theme.button)),
        )];

      case UpdateStatus.error:
        return [
          _cancelBtn(context, ref, theme),
          const SizedBox(width: 4),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.button,
              foregroundColor: theme.onButtonFill,
            ),
            onPressed: notifier.checkForUpdate,
            child: const Text('Retry'),
          ),
        ];
    }
  }

  Widget _cancelBtn(
    BuildContext context,
    WidgetRef ref,
    AppThemeData theme, {
    bool disabled = false,
  }) {
    return TextButton(
      onPressed: disabled
          ? null
          : () {
              ref.read(updateProvider.notifier).reset();
              Navigator.of(context).pop();
            },
      child: Text('Cancel', style: TextStyle(color: theme.subtext)),
    );
  }
}

// ── Body (switches on status) ─────────────────────────────────────────────────

class _UpdateDialogBody extends StatelessWidget {
  final UpdateState state;
  const _UpdateDialogBody({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    switch (state.status) {
      case UpdateStatus.idle:
      case UpdateStatus.checking:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: theme.button),
              const SizedBox(height: 16),
              Text(
                'Checking for updates…',
                style: TextStyle(color: theme.subtext),
              ),
            ],
          ),
        );

      case UpdateStatus.upToDate:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline,
                  color: theme.nowPlayingAccent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'You\'re up to date!',
                      style: TextStyle(
                          color: theme.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Version ${state.result?.currentVersion ?? ''} is the latest.',
                      style: TextStyle(color: theme.subtext, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.available:
        final result = state.result!;
        final isUnsupported = !Platform.isWindows && !Platform.isAndroid;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Version badge row
            Row(
              children: [
                Icon(Icons.new_releases_outlined,
                    color: theme.nowPlayingAccent, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Version ${result.latestVersion} is available',
                    style: TextStyle(
                        color: theme.text, fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.button.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'v${result.currentVersion} → v${result.latestVersion}',
                    style: TextStyle(
                        color: theme.button,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),

            // Platform note for macOS/Linux
            if (isUnsupported) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.highlight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: theme.subtext, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-update for ${Platform.isMacOS ? 'macOS' : 'Linux'} '
                        'is coming soon. Click "Download from GitHub" to update manually.',
                        style:
                            TextStyle(color: theme.subtext, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Release notes
            if (result.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'What\'s new:',
                style: TextStyle(
                    color: theme.subtext,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: theme.highlight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      result.releaseNotes,
                      style:
                          TextStyle(color: theme.subtext, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );

      case UpdateStatus.downloading:
        final pct = (state.downloadProgress * 100).toStringAsFixed(0);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Downloading update…',
                style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: state.downloadProgress,
                  backgroundColor: theme.highlight,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.button),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$pct%',
                style: TextStyle(color: theme.subtext, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Text(
                'The app will close and restart automatically to finish the update.',
                style: TextStyle(color: theme.subtext, fontSize: 12),
              ),
            ],
          ),
        );

      case UpdateStatus.installing:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            Platform.isWindows
                ? 'Setup is running. Utify will close and reopen automatically '
                    'once the update has finished.'
                : 'Android installer opened. Confirm Install there to finish '
                    'updating Utify.',
            style: TextStyle(color: theme.subtext),
          ),
        );

      case UpdateStatus.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  color: theme.notificationError, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  state.errorMessage ?? 'An unknown error occurred.',
                  style: TextStyle(color: theme.subtext, fontSize: 13),
                ),
              ),
            ],
          ),
        );
    }
  }
}
