// ============================================================
// desktop/views/downloads_view.dart
//
// Desktop Downloads panel — matches the existing desktop UI style.
//
// Shows:
//   • Active downloads (queued / in-progress / paused) with progress
//   • Failed downloads with red error text + Retry button
//   • Completed downloads
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/download_index.dart';
import '../../providers/download_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/download_service.dart';
import '../../utils/thumbnail_url.dart';

class DownloadsView extends ConsumerWidget {
  const DownloadsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(downloadProvider);

    final active = dl.tasks.values
        .where((t) =>
            t.status == DownloadStatus.queued ||
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.paused)
        .toList();

    final failed = dl.tasks.values
        .where((t) => t.status == DownloadStatus.failed)
        .toList();

    final done = dl.downloaded;
    final downloadedSongs = dl.downloadedSongs;

    final totalMB = dl.totalSizeBytes / 1024 / 1024;
    final totalStr = totalMB >= 1024
        ? '${(totalMB / 1024).toStringAsFixed(1)} GB'
        : '${totalMB.toStringAsFixed(0)} MB';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Row(
            children: [
              const Text(
                'Downloads',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (done.isNotEmpty)
                TextButton.icon(
                  onPressed: () async {
                    final confirm = await _confirmRemoveAll(context);
                    if (confirm) {
                      ref.read(downloadProvider.notifier).deleteAllDownloads();
                    }
                  },
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 16),
                  label: const Text('Remove all',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
            ],
          ),
        ),
        if (done.isNotEmpty || active.isNotEmpty || failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            // Wrap in Row so totalStr can't overflow on long values.
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '${done.length} songs · $totalStr',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        if (done.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: FilledButton.icon(
              onPressed: () {
                ref.read(playerProvider.notifier).playSong(
                      downloadedSongs.first,
                      queue: downloadedSongs,
                    );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play all downloads'),
            ),
          ),
        Expanded(
          child: done.isEmpty && active.isEmpty && failed.isEmpty
              ? const _DesktopEmptyState()
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    if (active.isNotEmpty) ...[
                      _sectionHeader('IN PROGRESS'),
                      ...active.map(
                        (t) => _DesktopActiveTile(task: t, ref: ref),
                      ),
                    ],
                    if (failed.isNotEmpty) ...[
                      _sectionHeader('FAILED', color: Colors.redAccent),
                      ...failed.map(
                        (t) => _DesktopFailedTile(task: t, ref: ref),
                      ),
                    ],
                    if (done.isNotEmpty) ...[
                      _sectionHeader('DOWNLOADED'),
                      ...done.map(
                        (e) => _DesktopDoneTile(entry: e, ref: ref),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  static Widget _sectionHeader(String text, {Color color = Colors.white38}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Future<bool> _confirmRemoveAll(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Remove all downloads?'),
        content: const Text(
          'All downloaded files will be deleted from your device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Remove all',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

// ── Active task tile (desktop) ────────────────────────────────────────────────

class _DesktopActiveTile extends StatelessWidget {
  final DownloadTask task;
  final WidgetRef ref;

  const _DesktopActiveTile({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final song = task.song;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: task.status == DownloadStatus.downloading
            ? Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: task.progress < 0.01 ? null : task.progress,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF1DB954)),
                      minHeight: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(task.progress * 100).round()}%',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              )
            : Text(
                task.status == DownloadStatus.paused ? 'Paused' : 'Queued',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (task.status == DownloadStatus.downloading)
              _iconBtn(
                  Icons.pause,
                  () => ref
                      .read(downloadProvider.notifier)
                      .pauseDownload(song.id))
            else if (task.status == DownloadStatus.paused)
              _iconBtn(
                  Icons.play_arrow,
                  () => ref
                      .read(downloadProvider.notifier)
                      .resumeDownload(song.id)),
            _iconBtn(
                Icons.close,
                () => ref
                    .read(downloadProvider.notifier)
                    .cancelDownload(song.id)),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 16, color: Colors.white38),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      );
}

// ── Failed task tile (desktop) ────────────────────────────────────────────────

class _DesktopFailedTile extends StatelessWidget {
  final DownloadTask task;
  final WidgetRef ref;

  const _DesktopFailedTile({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final song = task.song;
    final errorMsg = task.error ?? 'Unknown error';

    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading:
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
        ),
        subtitle: Text(
          errorMsg,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () =>
                  ref.read(downloadProvider.notifier).retryDownload(song.id),
              child: const Text('Retry',
                  style: TextStyle(color: Color(0xFF1DB954), fontSize: 12)),
            ),
            _iconBtn(
                Icons.close,
                () => ref
                    .read(downloadProvider.notifier)
                    .cancelDownload(song.id)),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 16, color: Colors.white38),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      );
}

// ── Downloaded song tile (desktop) ────────────────────────────────────────────

class _DesktopDoneTile extends StatelessWidget {
  final DownloadIndexEntry entry;
  final WidgetRef ref;

  const _DesktopDoneTile({required this.entry, required this.ref});

  @override
  Widget build(BuildContext context) {
    final sizeMB = entry.sizeBytes / 1024 / 1024;
    final subtitle = [
      if (entry.artist.isNotEmpty) entry.artist,
      if (sizeMB > 0.1) '${sizeMB.toStringAsFixed(1)} MB',
      entry.format.toUpperCase(),
    ].join(' · ');

    final thumbFile =
        entry.thumbnailPath.isNotEmpty ? File(entry.thumbnailPath) : null;

    // hqdefault as network fallback — never maxresdefault.
    final fallbackThumb = ThumbnailUrl.videoFallbacks(entry.videoId).first;

    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: thumbFile != null && thumbFile.existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.file(
                  thumbFile,
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                ),
              )
            : SizedBox(
                width: 36,
                height: 36,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Image.network(
                    fallbackThumb,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.white10,
                      child: const Icon(Icons.music_note,
                          color: Colors.white24, size: 18),
                    ),
                  ),
                ),
              ),
        title: Text(
          entry.title.isNotEmpty ? entry.title : entry.videoId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_done_rounded,
                color: Color(0xFF1DB954), size: 14),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              icon:
                  const Icon(Icons.more_horiz, color: Colors.white24, size: 16),
              padding: EdgeInsets.zero,
              onSelected: (v) {
                if (v == 'remove') {
                  ref.read(downloadProvider.notifier).deleteSong(entry.videoId);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'remove',
                  child: Text(
                    'Remove download',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: () => ref.read(playerProvider.notifier).playSongFromDownload(
            entry,
            queue: ref.read(downloadProvider).downloadedSongs),
      ),
    );
  }
}

// ── Empty state (desktop) ─────────────────────────────────────────────────────

class _DesktopEmptyState extends StatelessWidget {
  const _DesktopEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 48,
            color: Colors.white.withValues(alpha: 0.12),
          ),
          const SizedBox(height: 12),
          Text(
            'No downloads yet',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Download songs to listen offline',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.2),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
