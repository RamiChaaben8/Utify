// ============================================================
// screens/downloads_screen.dart
//
// Mobile Downloads page — accessible from Library tab.
//
// Shows:
//   • Active downloads (queued / in-progress / paused)
//   • Failed downloads with error text + Retry button
//   • All downloaded songs with total size
//   • Per-song: play, remove download
//   • "Remove all downloads" button in overflow menu
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/download_index.dart';
import '../providers/download_provider.dart';
import '../providers/player_provider.dart';
import '../services/download_service.dart';
import '../utils/thumbnail_url.dart';
import '../widgets/app_thumbnail.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

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

    final totalMB  = dl.totalSizeBytes / 1024 / 1024;
    final totalStr = totalMB >= 1024
        ? '${(totalMB / 1024).toStringAsFixed(1)} GB'
        : '${totalMB.toStringAsFixed(0)} MB';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Downloads'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'remove_all') {
                final confirm = await _confirmRemoveAll(context);
                if (confirm && context.mounted) {
                  await ref.read(downloadProvider.notifier).deleteAllDownloads();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'remove_all',
                child: Text(
                  'Remove all downloads',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
      body: done.isEmpty && active.isEmpty && failed.isEmpty
          ? _EmptyState()
          : CustomScrollView(
              slivers: [
                // Storage info
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      '${done.length} songs · $totalStr',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),

                // ── Active tasks ─────────────────────────────────────
                if (active.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'IN PROGRESS',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _ActiveTaskTile(task: active[i], ref: ref),
                      childCount: active.length,
                    ),
                  ),
                ],

                // ── Failed tasks ──────────────────────────────────────
                if (failed.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'FAILED',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _FailedTaskTile(task: failed[i], ref: ref),
                      childCount: failed.length,
                    ),
                  ),
                ],

                // ── Completed ─────────────────────────────────────────
                if (done.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        'DOWNLOADED',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) =>
                          _DownloadedSongTile(entry: done[i], ref: ref),
                      childCount: done.length,
                    ),
                  ),
                ],

                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
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

// ── Active task tile ──────────────────────────────────────────────────────────

class _ActiveTaskTile extends StatelessWidget {
  final DownloadTask task;
  final WidgetRef    ref;

  const _ActiveTaskTile({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final song      = task.song;
    final thumbUrl  = ThumbnailUrl.normalize(song.thumbnailUrl, videoId: song.id);

    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        leading: AppThumbnail(imageUrl: thumbUrl.isNotEmpty ? thumbUrl : null),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: task.status == DownloadStatus.downloading
            ? LinearProgressIndicator(
                value: task.progress < 0.01 ? null : task.progress,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF1DB954)),
                minHeight: 2,
              )
            : Text(
                task.status == DownloadStatus.paused ? 'Paused' : 'Queued',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
        // Wrap trailing Row in an IntrinsicWidth so it cannot overflow.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (task.status == DownloadStatus.downloading)
              IconButton(
                icon: const Icon(Icons.pause,
                    color: Colors.white54, size: 20),
                onPressed: () => ref
                    .read(downloadProvider.notifier)
                    .pauseDownload(song.id),
              )
            else if (task.status == DownloadStatus.paused)
              IconButton(
                icon: const Icon(Icons.play_arrow,
                    color: Colors.white54, size: 20),
                onPressed: () => ref
                    .read(downloadProvider.notifier)
                    .resumeDownload(song.id),
              ),
            IconButton(
              icon: const Icon(Icons.close,
                  color: Colors.white38, size: 18),
              onPressed: () => ref
                  .read(downloadProvider.notifier)
                  .cancelDownload(song.id),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Failed task tile ──────────────────────────────────────────────────────────

class _FailedTaskTile extends StatelessWidget {
  final DownloadTask task;
  final WidgetRef    ref;

  const _FailedTaskTile({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final song     = task.song;
    final errorMsg = task.error ?? 'Unknown error';

    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        leading: const Icon(Icons.error_outline,
            color: Colors.redAccent, size: 36),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.redAccent, fontSize: 14),
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
              onPressed: () => ref
                  .read(downloadProvider.notifier)
                  .retryDownload(song.id),
              child: const Text('Retry',
                  style: TextStyle(color: Color(0xFF1DB954))),
            ),
            IconButton(
              icon: const Icon(Icons.close,
                  color: Colors.white38, size: 18),
              onPressed: () => ref
                  .read(downloadProvider.notifier)
                  .cancelDownload(song.id),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Downloaded song tile ──────────────────────────────────────────────────────

class _DownloadedSongTile extends StatelessWidget {
  final DownloadIndexEntry entry;
  final WidgetRef          ref;

  const _DownloadedSongTile({required this.entry, required this.ref});

  @override
  Widget build(BuildContext context) {
    final sizeMB   = entry.sizeBytes / 1024 / 1024;
    final subtitle = [
      entry.artist,
      if (sizeMB > 0) '${sizeMB.toStringAsFixed(1)} MB',
      entry.format.toUpperCase(),
    ].where((s) => s.isNotEmpty).join(' · ');

    final thumbFile = entry.thumbnailPath.isNotEmpty
        ? File(entry.thumbnailPath)
        : null;

    // Fallback thumbnail URL using hqdefault (never maxresdefault).
    final fallbackThumb = ThumbnailUrl.videoFallbacks(entry.videoId).first;

    return Material(
      color: Colors.transparent,
      child: ListTile(
        tileColor: Colors.transparent,
        leading: thumbFile != null && thumbFile.existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  thumbFile,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              )
            : AppThumbnail(imageUrl: fallbackThumb),
        title: Text(
          entry.title.isNotEmpty ? entry.title : entry.videoId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_done_rounded,
                color: Color(0xFF1DB954), size: 16),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert,
                  color: Colors.white38, size: 20),
              onSelected: (v) async {
                if (v == 'remove') {
                  await ref
                      .read(downloadProvider.notifier)
                      .deleteSong(entry.videoId);
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
        onTap: () =>
            ref.read(playerProvider.notifier).playSongFromDownload(entry),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 64,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 16),
          Text(
            'No downloads yet',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Download songs to listen offline',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.25),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
