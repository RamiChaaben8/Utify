// ============================================================
// desktop/player/queue_panel.dart
//
// Spotify-style queue side-panel for Windows desktop.
// Matches the mobile QueueScreen layout exactly:
//   • "NOW PLAYING" section with green-bordered tile
//   • "NEXT UP" section with count, drag-to-reorder, hover menu
//   • Same green accent colour (#1DB954)
//   • Clear queue button in header
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/song.dart';
import '../../providers/player_provider.dart';
import '../theme/desktop_theme.dart';
import '../theme/ui_sizes.dart';
import '../../widgets/artist_link.dart';
import '../widgets/song_leading_indicator.dart';

class QueuePanel extends ConsumerWidget {
  final VoidCallback onClose;

  /// Width to render at. When null the theme default for the current window
  /// is used instead. Shares the now-playing panel's width so switching
  /// between the two does not jump.
  final double? width;

  QueuePanel({super.key, required this.onClose, this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.watch(playerProvider);
    final queue = ps.queue;
    final currentIndex = ps.currentIndex;

    final hasCurrent = currentIndex >= 0 && currentIndex < queue.length;
    final currentSong = hasCurrent ? queue[currentIndex] : null;
    final upNext = hasCurrent ? queue.sublist(currentIndex + 1) : <Song>[];
    final layout = context.appTheme.layout;

    return Container(
      width: width ??
          (layout.squareNowPlayingArt
              ? layout.nowPlayingWidthFor(MediaQuery.of(context).size.width)
              : 320),
      decoration: BoxDecoration(
        color: context.appTheme.panelSurfaceColor,
        border: Border(left: BorderSide(color: context.appTheme.dividerColor)),
        borderRadius: layout.squareNowPlayingArt
            ? BorderRadius.circular(layout.panelRadius)
            : null,
      ),
      child: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────
          _Header(
            queueLength: queue.length,
            hasUpNext: upNext.isNotEmpty,
            currentIndex: currentIndex,
            onClose: onClose,
            onClear: () {
              final n = ref.read(playerProvider.notifier);
              for (int i = queue.length - 1; i > currentIndex; i--) {
                n.removeFromQueue(i);
              }
            },
          ),

          // ── Body ──────────────────────────────────────────────────────
          Expanded(
            child: queue.isEmpty
                ? _Empty()
                : _Body(
                    queue: queue,
                    currentIndex: currentIndex,
                    currentSong: currentSong,
                    upNext: upNext,
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final int queueLength;
  final bool hasUpNext;
  final int currentIndex;
  final VoidCallback onClose;
  final VoidCallback onClear;

  _Header({
    required this.queueLength,
    required this.hasUpNext,
    required this.currentIndex,
    required this.onClose,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 12, vertical: QueueSizes.of.headerPadV),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: context.appTheme.dividerColor)),
      ),
      // The taller title row drives its own height, so let it grow instead of
      // forcing the header back to the old compact height.
      child: IntrinsicHeight(
        child: Row(
          children: [
            Icon(Icons.queue_music,
                color: context.appTheme.iconColor(context.appTheme.button),
                size: 26),
            SizedBox(width: 8),
            Text(
              'Queue',
              style: TextStyle(
                color: context.appTheme.text,
                fontSize: 24,
                height: 1.2,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: 8),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: context.appTheme.usesModernDesign
                    ? context.appTheme.highlight
                    : context.appTheme.button.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$queueLength',
                style: TextStyle(
                  color: context.appTheme.subtext,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Spacer(),
            if (hasUpNext)
              Tooltip(
                message: 'Clear queue',
                child: IconButton(
                  icon: Icon(Icons.clear_all,
                      color: context.appTheme.subtext, size: 18),
                  onPressed: onClear,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ),
            Tooltip(
              message: 'Close queue',
              child: IconButton(
                icon: Icon(Icons.close,
                    color: context.appTheme.subtext, size: 18),
                onPressed: onClose,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _Empty extends StatelessWidget {
  _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `shadow` (the divider token) is ~1.6:1 on the sidebar surface —
          // these empty-state glyphs and helper lines were invisible.
          Icon(Icons.queue_music, color: context.appTheme.iconDefault, size: 48),
          SizedBox(height: 12),
          Text('Queue is empty',
              style: TextStyle(
                  color: context.appTheme.subtext,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text('Add songs to start playing',
              style: TextStyle(color: context.appTheme.subtext, fontSize: 12)),
        ],
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────────────────

class _Body extends ConsumerWidget {
  final List<Song> queue;
  final int currentIndex;
  final Song? currentSong;
  final List<Song> upNext;

  _Body({
    required this.queue,
    required this.currentIndex,
    required this.currentSong,
    required this.upNext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomScrollView(
      slivers: [
        // ── NOW PLAYING ────────────────────────────────────────────────
        if (currentSong != null) ...[
          _SectionHeader(label: 'NOW PLAYING'),
          SliverToBoxAdapter(child: _NowPlayingTile(song: currentSong!)),
        ],

        // ── NEXT UP ────────────────────────────────────────────────────
        if (upNext.isNotEmpty) ...[
          _SectionHeader(label: 'NEXT UP  •  ${upNext.length} songs'),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorder: (oldIndex, newIndex) {
              final qOld = currentIndex + 1 + oldIndex;
              final qNew = currentIndex + 1 + newIndex;
              ref.read(playerProvider.notifier).reorderQueue(qOld, qNew);
            },
            // Match the panel surface, not `main` — otherwise the lifted
            // card is a near-black hole floating over the sidebar.
            proxyDecorator: (child, index, animation) => Material(
              color: context.appTheme.panelSurfaceColor,
              borderRadius: BorderRadius.circular(8),
              elevation: 6,
              child: child,
            ),
            itemBuilder: (ctx, i) {
              final song = upNext[i];
              final queueIndex = currentIndex + 1 + i;
              return _UpNextTile(
                key: ValueKey('${song.id}_$queueIndex'),
                song: song,
                queueIndex: queueIndex,
                slotIndex: i,
              );
            },
          ),
          SliverToBoxAdapter(child: SizedBox(height: 60)),
        ] else if (currentSong != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(
                child: Text(
                  'Nothing queued after this',
                  style:
                      TextStyle(color: context.appTheme.subtext, fontSize: 12),
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
  _SectionHeader({required this.label});

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
  _SectionHeaderDelegate({required this.label});

  @override
  double get minExtent => QueueSizes.of.sectionHeight;
  @override
  double get maxExtent => QueueSizes.of.sectionHeight;

  @override
  Widget build(BuildContext ctx, double shrinkOffset, bool overlaps) {
    return Container(
      // Must be the panel surface: `main` is darker than `sidebar`, so the
      // pinned "NOW PLAYING"/"NEXT UP" header showed as a dark seam with rows
      // sliding under a differently coloured strip.
      color: ctx.appTheme.panelSurfaceColor,
      padding: EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          color: ctx.appTheme.nowPlayingAccent,
          fontSize: QueueSizes.of.sectionLabel,
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

class _NowPlayingTile extends ConsumerWidget {
  final Song song;
  _NowPlayingTile({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const s = QueueSizes.of;
    final isPlaying = ref.watch(playerProvider.select((p) => p.isPlaying));
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.appTheme.usesModernDesign
            ? context.appTheme.highlight
            : context.appTheme.button.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: context.appTheme.usesModernDesign
                ? context.appTheme.highlight
                : context.appTheme.button.withValues(alpha: 0.25)),
      ),
      child: ListTile(
        dense: true,
        contentPadding:
            EdgeInsets.symmetric(horizontal: s.rowPadH, vertical: s.rowPadV),
        leading: _Thumb(
          url: song.thumbnailUrl,
          playing: true,
          isPlaying: isPlaying,
          size: s.thumb,
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.appTheme.nowPlayingAccent,
            fontWeight: FontWeight.bold,
            fontSize: s.songTitle,
          ),
        ),
        subtitle: ArtistNames(
          refs: song.artistRefs,
          fallbackName: song.channelName,
          maxLines: 1,
          style: TextStyle(
              color: context.appTheme.subtext, fontSize: s.songSubtitle),
          hoverStyle: TextStyle(
              color: context.appTheme.text,
              fontSize: s.songSubtitle,
              decoration: TextDecoration.underline,
              decorationColor: context.appTheme.text),
        ),
        trailing: EqualizerBars(
          color: context.appTheme.nowPlayingAccent,
          size: s.equalizer,
          animating: isPlaying,
        ),
      ),
    );
  }
}

// ─── UP NEXT tile ─────────────────────────────────────────────────────────────

class _UpNextTile extends ConsumerStatefulWidget {
  final Song song;
  final int queueIndex;
  final int slotIndex;

  _UpNextTile({
    super.key,
    required this.song,
    required this.queueIndex,
    required this.slotIndex,
  });

  @override
  ConsumerState<_UpNextTile> createState() => _UpNextTileState();
}

class _UpNextTileState extends ConsumerState<_UpNextTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const s = QueueSizes.of;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hovered
                // Lime @5% tinted the row green; every other list uses the
                // neutral highlight wash.
                ? context.appTheme.highlight
                : context.appTheme.panelSurfaceColor.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.symmetric(
                horizontal: s.rowPadH, vertical: s.rowPadV),
            leading: _Thumb(
                url: widget.song.thumbnailUrl, playing: false, size: s.thumb),
            title: Text(
              widget.song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: context.appTheme.text, fontSize: s.songTitle),
            ),
            subtitle: ArtistNames(
              refs: widget.song.artistRefs,
              fallbackName: widget.song.channelName,
              maxLines: 1,
              style: TextStyle(
                  color: context.appTheme.subtext, fontSize: s.songSubtitle),
              hoverStyle: TextStyle(
                  color: context.appTheme.text,
                  fontSize: s.songSubtitle,
                  decoration: TextDecoration.underline,
                  decorationColor: context.appTheme.text),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Remove button (visible on hover)
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: Duration(milliseconds: 150),
                  child: IconButton(
                    icon: Icon(Icons.close,
                        color: context.appTheme.subtext, size: s.rowActionIcon),
                    onPressed: () => ref
                        .read(playerProvider.notifier)
                        .removeFromQueue(widget.queueIndex),
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: s.rowActionTap, minHeight: s.rowActionTap),
                  ),
                ),
                // Context menu (visible on hover)
                AnimatedOpacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  duration: Duration(milliseconds: 150),
                  child: IconButton(
                    icon: Icon(Icons.more_horiz,
                        color: context.appTheme.subtext, size: s.rowActionIcon),
                    onPressed: () {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box == null) return;
                      final pos = box.localToGlobal(Offset.zero);
                      _showContextMenu(
                          context,
                          Offset(pos.dx + box.size.width,
                              pos.dy + box.size.height / 2));
                    },
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: s.rowActionTap, minHeight: s.rowActionTap),
                  ),
                ),
                // Drag handle
                ReorderableDragStartListener(
                  index: widget.slotIndex,
                  child: Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(Icons.drag_handle,
                        color: context.appTheme.iconDefault, size: s.dragHandle),
                  ),
                ),
              ],
            ),
            onTap: () {
              final queue = ref.read(playerProvider).queue;
              ref.read(playerProvider.notifier).playSong(
                    widget.song,
                    queue: queue,
                  );
            },
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      color: context.appTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _menuItem('play', Icons.play_arrow_outlined, 'Play now'),
        _menuItem('playNext', Icons.queue_play_next, 'Play next'),
        _menuItem('addToEnd', Icons.add_to_queue, 'Move to end'),
        PopupMenuDivider(),
        _menuItem('remove', Icons.remove_circle_outline, 'Remove',
            color: context.appTheme.notificationError),
      ],
    );

    if (!mounted) return;
    final n = ref.read(playerProvider.notifier);

    switch (selected) {
      case 'play':
        n.playSong(widget.song, queue: ref.read(playerProvider).queue);
      case 'playNext':
        n.removeFromQueue(widget.queueIndex);
        n.playNext(widget.song);
      case 'addToEnd':
        n.removeFromQueue(widget.queueIndex);
        n.addToQueue(widget.song);
      case 'remove':
        n.removeFromQueue(widget.queueIndex);
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final c = color ?? context.appTheme.text;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: c, size: 16),
          SizedBox(width: 10),
          Text(label, style: TextStyle(color: c, fontSize: 13)),
        ],
      ),
    );
  }
}

// ─── Thumbnail ────────────────────────────────────────────────────────────────

class _Thumb extends StatelessWidget {
  final String url;

  /// Draw the "now playing" overlay on the artwork.
  final bool playing;

  /// Whether the bars inside the overlay should animate. When false they
  /// rest low and static.
  final bool isPlaying;
  final double size;

  _Thumb({
    required this.url,
    required this.playing,
    this.isPlaying = true,
    this.size = 40,
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
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                      width: size, height: size, color: context.appTheme.card),
                  errorWidget: (_, __, ___) => _placeholder(context),
                )
              : _placeholder(context),
        ),
        if (playing)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: context.appTheme.shadow.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: EqualizerBars(
                color: context.appTheme.nowPlayingAccent,
                size: size * 0.55,
                animating: isPlaying,
              ),
            ),
          ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        width: size,
        height: size,
        color: context.appTheme.card,
        child: Icon(Icons.music_note,
            color: context.appTheme.subtext.withValues(alpha: 0.45),
            size: size * 0.42),
      );
}
