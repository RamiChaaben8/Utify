// ============================================================
// screens/queue_screen.dart
//
// Spotify-style queue screen.
//
// Features
// ─────────────────────────────────────────────────────────────
// • Two sections: "NOW PLAYING" and "NEXT UP"
// • Tap any song to play it immediately from that position
// • Swipe-to-dismiss on "NEXT UP" tracks
// • Long-press → context menu (Play Next, Remove, Add to Queue)
// • Drag-handle reorder (hold drag handle to reorder)
// • "Clear Queue" action in the app-bar menu
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/artwork_cache_manager.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final currentIndex = ref.watch(playerProvider.select((s) => s.currentIndex));

    final hasCurrent = currentIndex >= 0 && currentIndex < queue.length;
    final currentSong = hasCurrent ? queue[currentIndex] : null;
    // Songs that come after the current index
    final upNext = hasCurrent ? queue.sublist(currentIndex + 1) : [];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text(
          'Queue',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          if (upNext.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: const Color(0xFF1A1A1A),
              onSelected: (v) {
                if (v == 'clear') {
                  // Remove all tracks after current
                  final notifier = ref.read(playerProvider.notifier);
                  for (int i = queue.length - 1; i > currentIndex; i--) {
                    notifier.removeFromQueue(i);
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.clear_all, color: Colors.white70, size: 18),
                      SizedBox(width: 12),
                      Text('Clear queue',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: queue.isEmpty
            ? _EmptyQueue()
            : _QueueList(
                queue: queue,
                currentIndex: currentIndex,
                currentSong: currentSong,
                upNext: upNext,
              ),
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyQueue extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_music, color: Color(0xFF3A3A3A), size: 64),
          SizedBox(height: 16),
          Text(
            'Queue is empty',
            style: TextStyle(
              color: Color(0xFFB3B3B3),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Add songs to start playing',
            style: TextStyle(color: Color(0xFF555555), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─── Queue list ───────────────────────────────────────────────────────────────

class _QueueList extends ConsumerWidget {
  final List<Song> queue;
  final int currentIndex;
  final Song? currentSong;
  final List upNext; // List<Song> after currentIndex

  const _QueueList({
    required this.queue,
    required this.currentIndex,
    required this.currentSong,
    required this.upNext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We use a CustomScrollView so we can mix a pinned SliverAppBar-style
    // sticky header with a ReorderableListView's sliver version.
    //
    // Sections:
    //   0   → "NOW PLAYING" header  (non-reorderable, pinned)
    //   1   → current song tile     (non-reorderable)
    //   2   → "NEXT UP" header      (pinned if upNext non-empty)
    //   3.. → upNext tiles          (reorderable, swipe-to-dismiss)
    //
    // Because ReorderableListView can only manage one contiguous indexed
    // list, we use a plain ListView for the whole thing but implement
    // drag reorder ourselves via ReorderableListView on just the upNext
    // segment, wrapped in a SliverToBoxAdapter so it doesn't conflict
    // with outer scroll.

    final hasNext = upNext.isNotEmpty;

    return CustomScrollView(
      slivers: [
        // ── NOW PLAYING header ────────────────────────────────────────
        if (currentSong != null) ...[
          _SectionHeader(label: 'NOW PLAYING'),
          SliverToBoxAdapter(
            child: _NowPlayingTile(song: currentSong!),
          ),
        ],

        // ── NEXT UP header ────────────────────────────────────────────
        if (hasNext) ...[
          _SectionHeader(label: 'NEXT UP  •  ${upNext.length} songs'),
          // Reorderable sliver for the "up next" portion
          SliverReorderableList(
            itemCount: upNext.length,
            onReorder: (oldIndex, newIndex) {
              // Map upNext indices back to full-queue indices
              final qOld = currentIndex + 1 + oldIndex;
              int qNew = currentIndex + 1 + newIndex;
              ref.read(playerProvider.notifier).reorderQueue(qOld, qNew);
            },
            proxyDecorator: (child, index, animation) {
              return Material(
                color: const Color(0xFF252525),
                borderRadius: BorderRadius.circular(8),
                elevation: 8,
                child: child,
              );
            },
            itemBuilder: (ctx, i) {
              final song = upNext[i] as Song;
              final queueIndex = currentIndex + 1 + i;
              return _UpNextTile(
                key: ValueKey('${song.id}_$queueIndex'),
                song: song,
                index: queueIndex,
                slotIndex: i,
              );
            },
          ),
          // Bottom padding
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ] else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Center(
                child: Text(
                  'Nothing queued after this song',
                  style:
                      const TextStyle(color: Color(0xFF555555), fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _SectionHeaderDelegate(label: label),
    );
  }
}

class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  const _SectionHeaderDelegate({required this.label});

  @override
  double get minExtent => 36;
  @override
  double get maxExtent => 36;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: const Color(0xFF0A0A0A),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF1DB954),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeaderDelegate old) => old.label != label;
}

// ─── NOW PLAYING tile ─────────────────────────────────────────────────────────

class _NowPlayingTile extends StatelessWidget {
  final Song song;
  const _NowPlayingTile({required this.song});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1DB954).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1DB954).withOpacity(0.25)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: _Thumbnail(url: song.thumbnailUrl, playing: true),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF1DB954),
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          song.channelName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
        ),
        trailing:
            const Icon(Icons.graphic_eq, color: Color(0xFF1DB954), size: 22),
      ),
    );
  }
}

// ─── UP NEXT tile (swipe + long-press + tap-to-play) ─────────────────────────

class _UpNextTile extends ConsumerWidget {
  final Song song;
  final int index; // full-queue index
  final int slotIndex; // index within upNext list

  const _UpNextTile({
    super.key,
    required this.song,
    required this.index,
    required this.slotIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey('dismiss_${song.id}_$index'),
      direction: DismissDirection.endToStart,
      background: _SwipeBackground(),
      onDismissed: (_) {
        ref.read(playerProvider.notifier).removeFromQueue(index);
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed "${song.title}"'),
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: 'UNDO',
              textColor: const Color(0xFF1DB954),
              onPressed: () {
                // Re-insert at the same position
                ref.read(playerProvider.notifier).addToQueue(song);
              },
            ),
          ),
        );
      },
      child: _buildTile(context, ref),
    );
  }

  Widget _buildTile(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: () => _showContextMenu(context, ref),
      child: ListTile(
        key: ValueKey('tile_${song.id}_$index'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _Thumbnail(url: song.thumbnailUrl, playing: false),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          song.channelName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Remove button
            IconButton(
              icon: const Icon(Icons.close, color: Color(0xFF555555), size: 18),
              onPressed: () =>
                  ref.read(playerProvider.notifier).removeFromQueue(index),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            // Drag handle
            ReorderableDragStartListener(
              index: slotIndex,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child:
                    Icon(Icons.drag_handle, color: Color(0xFF3A3A3A), size: 22),
              ),
            ),
          ],
        ),
        onTap: () {
          // Play this song immediately from its position in the queue
          final queue = ref.read(playerProvider).queue;
          ref.read(playerProvider.notifier).playSong(song, queue: queue);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showContextMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _QueueContextMenu(song: song, queueIndex: index),
    );
  }
}

// ─── Context menu sheet ───────────────────────────────────────────────────────

class _QueueContextMenu extends ConsumerWidget {
  final Song song;
  final int queueIndex;
  const _QueueContextMenu({required this.song, required this.queueIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF555555),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Song header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _Thumbnail(url: song.thumbnailUrl, playing: false, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14)),
                      Text(song.channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFFB3B3B3), fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xFF2A2A2A), height: 1),

          // Play Next
          ListTile(
            leading: const Icon(Icons.queue_play_next,
                color: Colors.white70, size: 22),
            title:
                const Text('Play next', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              // Remove from current position first, then insert after current
              ref.read(playerProvider.notifier).removeFromQueue(queueIndex);
              ref.read(playerProvider.notifier).playNext(song);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('"${song.title}" will play next'),
                  duration: const Duration(seconds: 2),
                  backgroundColor: const Color(0xFF1DB954),
                ),
              );
            },
          ),

          // Add to end of queue
          ListTile(
            leading:
                const Icon(Icons.add_to_queue, color: Colors.white70, size: 22),
            title: const Text('Add to queue',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Move to end',
                style: TextStyle(color: Color(0xFF888888), fontSize: 11)),
            onTap: () {
              Navigator.pop(context);
              // Move to end: remove, then add back
              ref.read(playerProvider.notifier).removeFromQueue(queueIndex);
              ref.read(playerProvider.notifier).addToQueue(song);
            },
          ),

          // Remove
          ListTile(
            leading: const Icon(Icons.remove_circle_outline,
                color: Colors.redAccent, size: 22),
            title: const Text('Remove from queue',
                style: TextStyle(color: Colors.redAccent)),
            onTap: () {
              Navigator.pop(context);
              ref.read(playerProvider.notifier).removeFromQueue(queueIndex);
            },
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─── Swipe background ─────────────────────────────────────────────────────────

class _SwipeBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      color: Colors.red.withOpacity(0.15),
      child:
          const Icon(Icons.delete_outline, color: Colors.redAccent, size: 26),
    );
  }
}

// ─── Thumbnail ────────────────────────────────────────────────────────────────

class _Thumbnail extends StatelessWidget {
  final String url;
  final bool playing;
  final double size;

  const _Thumbnail({
    required this.url,
    required this.playing,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: url.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: url,
                  cacheManager: ArtworkCacheManager.instance,
                  memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                  memCacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                      width: size,
                      height: size,
                      color: const Color(0xFF282828)),
                  errorWidget: (_, __, ___) => _placeholder(size),
                )
              : _placeholder(size),
        ),
        if (playing)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.graphic_eq,
                color: Color(0xFF1DB954), size: 22),
          ),
      ],
    );
  }

  Widget _placeholder(double sz) {
    return Container(
      width: sz,
      height: sz,
      color: const Color(0xFF282828),
      child: const Icon(Icons.music_note, color: Color(0xFF3A3A3A), size: 22),
    );
  }
}
