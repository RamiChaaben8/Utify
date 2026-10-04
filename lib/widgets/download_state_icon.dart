// ============================================================
// widgets/download_state_icon.dart
//
// Compact icon that shows the download state of a song.
//
// States:
//   • Not downloaded: no icon (null/empty)
//   • Queued:         cloud_download outline, muted
//   • Downloading:    tiny circular progress + percentage
//   • Paused:         pause icon, muted
//   • Downloaded:     cloud_done filled, accent green
//
// Usage: Drop inside any song tile's trailing area.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/download_provider.dart';
import '../services/download_service.dart';

class DownloadStateIcon extends ConsumerWidget {
  final String videoId;
  final double size;

  const DownloadStateIcon({
    super.key,
    required this.videoId,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(downloadProvider);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withOpacity(0.4);
    const green = Color(0xFF1DB954);

    if (dl.isDownloaded(videoId) && !dl.isQueued(videoId)) {
      return Icon(Icons.cloud_done_rounded, size: size, color: green);
    }

    final task = dl.tasks[videoId];
    if (task == null) return const SizedBox.shrink();

    switch (task.status) {
      case DownloadStatus.queued:
        return Icon(Icons.cloud_download_outlined, size: size, color: muted);

      case DownloadStatus.downloading:
        final progress = task.progress;
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress < 0.01 ? null : progress,
                strokeWidth: 2,
                valueColor: const AlwaysStoppedAnimation<Color>(green),
                backgroundColor: muted.withOpacity(0.2),
              ),
              if (progress > 0.01)
                Text(
                  '${(progress * 100).round()}',
                  style: TextStyle(
                    fontSize: size * 0.36,
                    color: green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        );

      case DownloadStatus.paused:
        return Icon(Icons.pause_circle_outline, size: size, color: muted);

      case DownloadStatus.done:
        return Icon(Icons.cloud_done_rounded, size: size, color: green);

      case DownloadStatus.failed:
        return Icon(Icons.error_outline, size: size, color: Colors.redAccent);
    }
  }
}
