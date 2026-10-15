// ============================================================
// desktop/now_playing/desktop_now_playing_panel.dart
//
// Right panel layout (fixed, never scrolls as a whole):
//
//   ┌──────────────────────────────────────┐
//   │  Video card  (fixed height, pinned)  │  ← never scrolls away
//   ├──────────────────────────────────────┤
//   │  [Lyrics] label  (fixed)             │
//   │  ─────────────────────────────────── │
//   │  lyric line 1                        │  ← only THIS inner box
//   │  lyric line 2                        │    scrolls (its own
//   │  …                                   │    ScrollController)
//   └──────────────────────────────────────┘
//
// Root Column has overflow:hidden (ClipRect). The ListView / any
// ancestor never scrolls. The Listener intercepts wheel events and
// routes them either to the inner lyrics scroller or the video resize.
// ============================================================

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/lyrics_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/youtube_service.dart';
import '../../widgets/artist_link.dart';
import '../../widgets/video_preview_widget.dart';
import '../theme/desktop_theme.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

const double _kVideoMin = 230.0;
const double _kBarWidth = 7.0;

const double _kSnapFrac = 0.10;
const int _kAnimMs = 150;
const int _kPauseMs = 3000;
const String _kPrefKey = 'now_playing_video_height';

/// Every theme remembers its own video card height, so resizing the card in
/// one theme never changes the size in another.
String _heightKey(String themeName) {
  final slug = themeName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return '${_kPrefKey}_$slug';
}

// ─── Panel ───────────────────────────────────────────────────────────────────

class DesktopNowPlayingPanel extends ConsumerStatefulWidget {
  /// Width to render at. When null the theme default for the current window
  /// is used instead.
  final double? width;

  const DesktopNowPlayingPanel({super.key, this.width});

  @override
  ConsumerState<DesktopNowPlayingPanel> createState() =>
      _DesktopNowPlayingPanelState();
}

class _DesktopNowPlayingPanelState
    extends ConsumerState<DesktopNowPlayingPanel> {
  // Lyrics-only scroll controller — the panel itself never scrolls
  final ScrollController _lyricsScroll = ScrollController();

  // Video resize
  double _videoHeight = _kVideoMin;
  double _videoMax = _kVideoMin;
  String? _heightThemeName;
  bool _isDragging = false;
  double _dragStartThumbOffset = 0;

  // Lyrics sync
  String? _lastVideoId;
  int _activeIndex = -1;
  final List<GlobalKey> _lineKeys = [];
  bool _autoScrollPaused = false;
  Timer? _resumeTimer;
  bool _isAutoScrolling = false;

  @override
  void initState() {
    super.initState();
    _lyricsScroll.addListener(_onLyricsScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload the stored height whenever the active theme changes so each
    // theme keeps its own video card size.
    final themeName = context.appTheme.name;
    if (_heightThemeName == themeName) return;

    _heightThemeName = themeName;
    _videoHeight = _kVideoMin;
    unawaited(_loadHeight(themeName));
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _lyricsScroll
      ..removeListener(_onLyricsScroll)
      ..dispose();
    super.dispose();
  }

  // ── Persistence ──────────────────────────────────────────────────────────

  Future<void> _loadHeight(String themeName) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _heightThemeName != themeName) return;
    // Fall back to the pre-per-theme value so existing sizes are not lost.
    final saved = prefs.getDouble(_heightKey(themeName)) ??
        prefs.getDouble(_kPrefKey);
    if (saved != null && saved >= _kVideoMin) {
      setState(() {
        _videoHeight = saved;
      });
    }
  }

  Future<void> _saveHeight(double h) async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = _heightThemeName;
    if (themeName == null) return;
    await prefs.setDouble(_heightKey(themeName), h);
  }

  // ── Height helpers ────────────────────────────────────────────────────────

  double _clamp(double h) => h.clamp(_kVideoMin, _videoMax);

  double _snapIfClose(double h) {
    final range = _videoMax - _kVideoMin;
    if (range <= 0) return h;
    if ((h - _kVideoMin) / range < _kSnapFrac) return _kVideoMin;
    if ((_videoMax - h) / range < _kSnapFrac) return _videoMax;
    return h;
  }

  void _setHeight(double h, {bool snap = false}) {
    double next = _clamp(h);
    if (snap) next = _snapIfClose(next);
    if (next == _videoHeight) return;
    setState(() {
      _videoHeight = next;
    });
    _saveHeight(next);
  }

  double _thumbOffsetToHeight(double offset, double trackH) {
    if (trackH <= 0) return _kVideoMin;
    return _kVideoMin +
        (offset / trackH).clamp(0.0, 1.0) * (_videoMax - _kVideoMin);
  }

  // ── Wheel routing ─────────────────────────────────────────────────────────
  //
  // Scrolling UP   → grow video (if below max), else scroll lyrics up.
  // Scrolling DOWN → scroll lyrics down; only shrink video when lyrics
  //                  are already at scrollTop == 0.
  //
  // We call jumpTo() on _lyricsScroll directly so the event never
  // bubbles up to any ancestor scroller.

  // Wheel events over the video card call _setHeight directly.

  void _scrollLyricsBy(double dy) {
    if (!_lyricsScroll.hasClients) return;
    _lyricsScroll.jumpTo(
      (_lyricsScroll.offset + dy)
          .clamp(0.0, _lyricsScroll.position.maxScrollExtent),
    );
  }

  // ── Auto-scroll pause on manual scroll ───────────────────────────────────

  void _onLyricsScroll() {
    if (_isAutoScrolling) return;
    _autoScrollPaused = true;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(
      const Duration(milliseconds: _kPauseMs),
      () => _autoScrollPaused = false,
    );
  }

  // ── Lyrics sync ───────────────────────────────────────────────────────────

  void _syncActive(List<LyricLine> lines, Duration pos) {
    if (_lineKeys.length != lines.length) {
      _lineKeys.clear();
      for (int i = 0; i < lines.length; i++) {
        _lineKeys.add(GlobalKey());
      }
    }
    var low = 0;
    var high = lines.length - 1;
    var active = -1;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (pos >= lines[middle].start) {
        active = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (active != _activeIndex) {
      _activeIndex = active;
      _autoScrollToLine(active);
    }
  }

  // Auto-scroll: compute the lyric line's offset inside the lyrics
  // ScrollView and call animateTo() on _lyricsScroll directly.
  // We do NOT use Scrollable.ensureVisible / scrollIntoView because
  // those walk up every ancestor and would move the video card.
  void _autoScrollToLine(int index) {
    if (_autoScrollPaused) return;
    if (index < 0 || index >= _lineKeys.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _lineKeys[index];
      final ctx = key.currentContext;
      if (ctx == null || !_lyricsScroll.hasClients) return;

      // Find the RenderBox of the lyric line and the lyrics scroll viewport
      final RenderBox? lineBox = ctx.findRenderObject() as RenderBox?;
      final RenderBox? viewBox = _lyricsScroll.position.context.storageContext
          .findRenderObject() as RenderBox?;

      if (lineBox == null || viewBox == null) return;

      // Position of the line relative to the top of the scroll viewport
      final lineOffset =
          lineBox.localToGlobal(Offset.zero, ancestor: viewBox).dy;
      final viewH = _lyricsScroll.position.viewportDimension;
      final target = _lyricsScroll.offset +
          lineOffset -
          viewH * 0.35; // keep line ~35% from top

      _isAutoScrolling = true;
      _lyricsScroll
          .animateTo(
            target.clamp(0.0, _lyricsScroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOut,
          )
          .then((_) => _isAutoScrolling = false);
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(playerProvider);
    final lyrics = ref.watch(lyricsProvider);
    final song = ps.currentSong;

    if (song != null && !song.isLocal) {
      if (song.id != _lastVideoId || lyrics.videoId != song.id) {
        _lastVideoId = song.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(lyricsProvider.notifier).fetchFor(song.id, song: song);
        });
      }
    }

    if (lyrics.hasLyrics) _syncActive(lyrics.lines, ps.position);
    final layout = context.appTheme.layout;

    return Container(
      width: widget.width ??
          layout.nowPlayingWidthFor(MediaQuery.of(context).size.width),
      decoration: BoxDecoration(
        color: context.appTheme.panelSurfaceColor,
        borderRadius: context.appTheme.usesModernDesign
            ? BorderRadius.circular(layout.panelRadius)
            : BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
      ),
      clipBehavior: Clip.antiAlias,
      child: song == null || song.isLocal
          ? const _Placeholder()
          : _buildPanel(song, lyrics),
    );
  }

  Widget _buildPanel(dynamic song, LyricsState lyrics) {
    return LayoutBuilder(builder: (context, constraints) {
      final panelH = constraints.maxHeight;
      final layout = context.appTheme.layout;
      const double kLyricsMinH = 160.0;
      _videoMax =
          (panelH - kLyricsMinH).clamp(_kVideoMin, double.infinity).toDouble();
      if (_videoHeight > _videoMax) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _videoHeight > _videoMax) {
            setState(() => _videoHeight = _videoMax);
          }
        });
      }

      final dur =
          _isDragging ? Duration.zero : const Duration(milliseconds: _kAnimMs);

      final safeVideoH = _videoHeight.clamp(_kVideoMin, _videoMax).toDouble();

      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Main panel column ──────────────────────────────────
          Expanded(
            child: ClipRect(
              child: Column(
                children: [
                  // 1. Video card — wheel resizes, drag bar also resizes
                  Listener(
                    onPointerSignal: (event) {
                      if (event is! PointerScrollEvent) return;
                      _setHeight(_videoHeight - event.scrollDelta.dy);
                    },
                    child: AnimatedContainer(
                      duration: dur,
                      curve: Curves.easeOut,
                      height: safeVideoH,
                      child: _VideoCard(
                        song: song,
                        animationDuration: dur,
                      ),
                    ),
                  ),

                  // 2. Lyrics card — fills remaining space, only this scrolls
                  Expanded(
                    child: Listener(
                      onPointerSignal: (event) {
                        if (event is! PointerScrollEvent) return;
                        _scrollLyricsBy(event.scrollDelta.dy);
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                        child: Container(
                          decoration: BoxDecoration(
                            color: context.appTheme.lyricsCardColor,
                            borderRadius:
                                BorderRadius.circular(layout.lyricsCardRadius),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _LyricsHeader(),
                              Expanded(
                                child: _ThinScrollbar(
                                  controller: _lyricsScroll,
                                  child: _buildLyricsInner(
                                    lyrics,
                                    ref.watch(playerProvider).position,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Resize drag bar ──────────────────────────────────────
          _DragBar(
            panelHeight: panelH,
            videoHeight: safeVideoH,
              videoMin: _kVideoMin,
              videoMax: _videoMax,
              isDragging: _isDragging,
              onDragStart: (_, thumbOffset) => setState(() {
                _isDragging = true;
                _dragStartThumbOffset = thumbOffset;
              }),
              onDragUpdate: (dy, trackH) {
                final newOffset =
                    (_dragStartThumbOffset + dy).clamp(0.0, trackH);
                _setHeight(_thumbOffsetToHeight(newOffset, trackH));
              },
              onDragEnd: () {
                setState(() => _isDragging = false);
                _setHeight(_videoHeight, snap: true);
              },
              onTrackTap: (frac) => _setHeight(
                _kVideoMin + frac * (_videoMax - _kVideoMin),
                snap: true,
              ),
            ),
        ],
      );
    });
  }

  // The inner scrollable widget that holds only the lyric lines.
  Widget _buildLyricsInner(LyricsState lyrics, Duration position) {
    if (lyrics.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
                color: context.appTheme.usesModernDesign
                    ? context.appTheme.subtext
                    : context.appTheme.button,
                strokeWidth: 2),
            SizedBox(height: 10),
            Text('Loading lyrics…',
                style:
                    TextStyle(color: context.appTheme.subtext, fontSize: 13)),
          ],
        ),
      );
    }

    if (!lyrics.hasLyrics) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.music_off, color: context.appTheme.subtext, size: 36),
              SizedBox(height: 10),
              Text(
                lyrics.error ?? 'No lyrics available for this song.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.appTheme.subtext, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    // NeverScrollableScrollPhysics because wheel events are handled by
    // the Listener above — _scrollLyricsBy() drives _lyricsScroll directly.
    final isRtl = lyrics.isArabic;
    return Directionality(
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: ListView.builder(
        controller: _lyricsScroll,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        itemCount: lyrics.lines.length + 1, // +1 for footer
        itemBuilder: (context, i) {
          if (i == lyrics.lines.length) {
            return Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                lyrics.source == LyricsSource.lrclib ||
                        lyrics.source == LyricsSource.lrclibPlain
                    ? 'Lyrics provided by LRCLIB'
                    : 'Lyrics provided by YouTube',
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                style: TextStyle(color: context.appTheme.subtext, fontSize: 11),
              ),
            );
          }
          return _LyricLine(
            key: i < _lineKeys.length ? _lineKeys[i] : GlobalKey(),
            line: lyrics.lines[i],
            isActive: i == _activeIndex,
            position: position,
            isRtl: isRtl,
          );
        },
      ),
    );
  }
}

// ─── Lyrics header with optional track selector ───────────────────────────────

class _LyricsHeader extends ConsumerWidget {
  const _LyricsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider);
    final hasMultipleTracks = lyrics.availableTracks.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 8, 8),
          child: Row(
            children: [
              // "Lyrics" label
              Icon(Icons.lyrics_outlined,
                  color: context.appTheme.iconColor(context.appTheme.button),
                  size: 13),
              SizedBox(width: 5),
              Text(
                'Lyrics',
                style: TextStyle(
                  color: context.appTheme.lyricsLabelColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),

              const Spacer(),

              // Track selector — only shown when multiple tracks exist
              if (hasMultipleTracks) _TrackSelectorButton(lyrics: lyrics),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Divider(
              color: context.appTheme.dividerColor, height: 1, thickness: 1),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ─── Track selector button + dropdown ────────────────────────────────────────

class _TrackSelectorButton extends ConsumerWidget {
  final LyricsState lyrics;
  const _TrackSelectorButton({required this.lyrics});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedLabel = lyrics.selectedTrackLabel ??
        (lyrics.availableTracks.isNotEmpty
            ? lyrics.availableTracks.first.label
            : 'Auto');

    // Shorten the label for the button (strip "(auto-generated)" suffix)
    final shortLabel = selectedLabel
        .replaceAll(' (auto-generated)', '')
        .replaceAll(' (auto)', '');

    return GestureDetector(
      onTapDown: (details) => _showMenu(context, ref, details.globalPosition),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: context.appTheme.card,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: context.appTheme.dividerColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.subtitles_outlined,
                color: context.appTheme.iconColor(context.appTheme.button),
                size: 11),
            SizedBox(width: 4),
            Text(
              shortLabel,
              style: TextStyle(
                color: context.appTheme.iconColor(context.appTheme.button),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 3),
            Icon(Icons.arrow_drop_down,
                color: context.appTheme.iconColor(context.appTheme.button),
                size: 14),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref, Offset position) {
    final items = lyrics.availableTracks.map((track) {
      final isSelected = track.code == lyrics.selectedTrackCode;
      return PopupMenuItem<String>(
        value: track.code,
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: isSelected
                  ? Icon(
                      Icons.check,
                      color: context.appTheme.nowPlayingAccent,
                      size: 14,
                    )
                  : null,
            ),
            SizedBox(width: 4),
            Expanded(
              child: Text(
                track.label,
                // iconColor() demotes to grey in Verdant Night, which inverted
                // the emphasis: the *selected* track became the dimmest one.
                style: TextStyle(
                  color: isSelected
                      ? context.appTheme.nowPlayingAccent
                      : context.appTheme.subtext,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx - 160,
        position.dy,
        position.dx,
        position.dy + 40,
      ),
      color: context.appTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.appTheme.dividerColor),
      ),
      items: items,
    ).then((code) {
      if (code != null) {
        ref.read(lyricsProvider.notifier).selectTrack(code);
      }
    });
  }
}

// ─── Thin custom scrollbar ────────────────────────────────────────────────────

class _ThinScrollbar extends StatefulWidget {
  final Widget child;
  final ScrollController controller;

  const _ThinScrollbar({required this.child, required this.controller});

  @override
  State<_ThinScrollbar> createState() => _ThinScrollbarState();
}

class _ThinScrollbarState extends State<_ThinScrollbar> {
  static const double _kBarW = 6.0;
  static const double _kThumbW = 4.0;
  static const double _kThumbMinH = 32.0;
  static const double _kPadV = 8.0;

  bool _hovering = false;
  bool _dragging = false;
  double _dragStartLocalY = 0;
  double _dragStartScroll = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() => setState(() {});

  double _thumbH(double trackH) {
    final sc = widget.controller;
    // Guard: if trackH is too small to fit the minimum thumb, just fill it.
    if (trackH <= _kThumbMinH) return trackH.clamp(0.0, double.infinity);
    if (!sc.hasClients || sc.position.maxScrollExtent <= 0) return trackH;
    final visible = sc.position.viewportDimension;
    final total = visible + sc.position.maxScrollExtent;
    return (trackH * visible / total).clamp(_kThumbMinH, trackH);
  }

  double _thumbTop(double trackH) {
    final sc = widget.controller;
    if (!sc.hasClients || sc.position.maxScrollExtent <= 0) return 0;
    return (sc.offset / sc.position.maxScrollExtent) *
        (trackH - _thumbH(trackH));
  }

  void _dragStart(double localY) {
    setState(() {
      _dragging = true;
      _dragStartLocalY = localY;
      _dragStartScroll =
          widget.controller.hasClients ? widget.controller.offset : 0;
    });
  }

  void _dragUpdate(double localY, double trackH) {
    if (!_dragging || !widget.controller.hasClients) return;
    final dy = localY - _dragStartLocalY;
    final tH = _thumbH(trackH);
    final scrollRange = widget.controller.position.maxScrollExtent;
    final scrollable = trackH - tH;
    if (scrollable <= 0) return;
    widget.controller.jumpTo(
      (_dragStartScroll + dy / scrollable * scrollRange)
          .clamp(0.0, scrollRange),
    );
  }

  void _dragEnd() => setState(() => _dragging = false);

  void _trackTap(double localY, double trackH) {
    if (!widget.controller.hasClients) return;
    final tH = _thumbH(trackH);
    final frac = ((localY - tH / 2) / (trackH - tH)).clamp(0.0, 1.0);
    widget.controller.animateTo(
      frac * widget.controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use a Stack instead of a Row so the LayoutBuilder for the
    // scrollbar thumb always receives the same bounded constraints
    // as the child — a Row with CrossAxisAlignment.stretch can pass
    // infinite height to LayoutBuilder when the Row itself is unconstrained.
    return Stack(
      children: [
        // The scrollable content fills the whole box
        Positioned.fill(
          child: Padding(
            // Leave room for the scrollbar on the right
            padding: EdgeInsets.only(right: _kBarW),
            child: widget.child,
          ),
        ),

        // Scrollbar pinned to the right edge
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _kBarW,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: LayoutBuilder(builder: (context, constraints) {
              final totalH = constraints.maxHeight;
              final trackH = (totalH - 2 * _kPadV).clamp(0.0, double.infinity);
              return GestureDetector(
                onTapDown: (d) =>
                    _trackTap(d.localPosition.dy - _kPadV, trackH),
                onVerticalDragStart: (d) =>
                    _dragStart(d.localPosition.dy - _kPadV),
                onVerticalDragUpdate: (d) =>
                    _dragUpdate(d.localPosition.dy - _kPadV, trackH),
                onVerticalDragEnd: (_) => _dragEnd(),
                onVerticalDragCancel: () => _dragEnd(),
                child: SizedBox(
                  width: _kBarW,
                  height: totalH,
                  child: CustomPaint(
                    painter: _BarPainter(
                      trackH: trackH,
                      padV: _kPadV,
                      thumbTop: _thumbTop(trackH),
                      thumbH: _thumbH(trackH),
                      thumbW: _kThumbW,
                      barW: _kBarW,
                      thumbColor: context.appTheme.usesModernDesign
                          ? context.appTheme.scrollbarThumbColor
                          : (_hovering || _dragging)
                              ? context.appTheme.buttonActive
                              : context.appTheme.button,
                      trackColor: context.appTheme.usesModernDesign
                          ? Colors.transparent
                          : context.appTheme.main,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  final double trackH, padV, thumbTop, thumbH, thumbW, barW;
  final Color thumbColor, trackColor;

  const _BarPainter({
    required this.trackH,
    required this.padV,
    required this.thumbTop,
    required this.thumbH,
    required this.thumbW,
    required this.barW,
    required this.thumbColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = barW / 2;
    canvas.drawLine(
      Offset(cx, padV),
      Offset(cx, padV + trackH),
      Paint()
        ..color = trackColor
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(
        cx - thumbW / 2,
        padV + thumbTop,
        cx + thumbW / 2,
        padV + thumbTop + thumbH,
        Radius.circular(thumbW / 2),
      ),
      Paint()..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.thumbTop != thumbTop ||
      old.thumbH != thumbH ||
      old.thumbColor != thumbColor;
}

// ─── Resize drag bar (video height only) ─────────────────────────────────────

class _DragBar extends StatefulWidget {
  final double panelHeight, videoHeight, videoMin, videoMax;
  final bool isDragging;
  final void Function(double pointerY, double thumbOffset) onDragStart;
  final void Function(double dy, double trackH) onDragUpdate;
  final void Function() onDragEnd;
  final void Function(double frac) onTrackTap;

  const _DragBar({
    required this.panelHeight,
    required this.videoHeight,
    required this.videoMin,
    required this.videoMax,
    required this.isDragging,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTrackTap,
  });

  @override
  State<_DragBar> createState() => _DragBarState();
}

class _DragBarState extends State<_DragBar> {
  bool _hovering = false;

  static const double _kThumbH = 40.0;
  static const double _kThumbW = 4.0;
  static const double _kTrackPadV = 12.0;

  double get _trackH => widget.panelHeight - 2 * _kTrackPadV - _kThumbH;

  double get _thumbOffset {
    final range = widget.videoMax - widget.videoMin;
    if (range <= 0) return 0;
    return ((widget.videoHeight - widget.videoMin) / range).clamp(0.0, 1.0) *
        _trackH;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: (d) {
          final localY = d.localPosition.dy - _kTrackPadV;
          widget.onTrackTap((localY / (_trackH + _kThumbH)).clamp(0.0, 1.0));
        },
        onVerticalDragStart: (d) =>
            widget.onDragStart(d.globalPosition.dy, _thumbOffset),
        onVerticalDragUpdate: (d) => widget.onDragUpdate(d.delta.dy, _trackH),
        onVerticalDragEnd: (_) => widget.onDragEnd(),
        onVerticalDragCancel: () => widget.onDragEnd(),
        child: SizedBox(
          width: _kBarWidth,
          height: widget.panelHeight,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Container(
                width: 2,
                margin: EdgeInsets.symmetric(
                  vertical: _kTrackPadV,
                  horizontal: (_kBarWidth - 2) / 2,
                ),
                decoration: BoxDecoration(
                  color: context.appTheme.card,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              AnimatedPositioned(
                duration: widget.isDragging
                    ? Duration.zero
                    : const Duration(milliseconds: _kAnimMs),
                curve: Curves.easeOut,
                top: _kTrackPadV + _thumbOffset,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _kThumbW,
                  height: _kThumbH,
                  decoration: BoxDecoration(
                    color: _hovering || widget.isDragging
                        // button == buttonActive in Verdant Night, so the hover
                        // state produced no visual change at all.
                        ? context.appTheme.nowPlayingAccent
                        : context.appTheme.button,
                    borderRadius: BorderRadius.circular(_kThumbW / 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Video card ───────────────────────────────────────────────────────────────

class _VideoCard extends StatelessWidget {
  final dynamic song;
  final Duration animationDuration;

  const _VideoCard({
    required this.song,
    this.animationDuration = const Duration(milliseconds: _kAnimMs),
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          // This is the letterbox backdrop behind the video. `text` is lime in
          // Verdant Night, so a lime rectangle flashed behind every video —
          // and the title below (lime, with a lime glow) sat on top of it.
          color: context.appTheme.card,
          child: VideoPreviewWidget(
            imageUrl: song.thumbnailUrl,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 110,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.appTheme.main.withValues(alpha: 0),
                  context.appTheme.shadow.withValues(alpha: 0.95)
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appTheme.lyricsActiveLineColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(
                              blurRadius: 10,
                              color: context.appTheme.main.withValues(alpha: 0.9))
                        ],
                      ),
                    ),
                    SizedBox(height: 3),
                    ArtistNames(
                      refs: song.artistRefs,
                      fallbackName: song.channelName,
                      maxLines: 1,
                      style: TextStyle(
                        color: context.appTheme.subtext,
                        fontSize: 12,
                        shadows: [
                          Shadow(
                              blurRadius: 8,
                              color:
                                  context.appTheme.main.withValues(alpha: 0.9))
                        ],
                      ),
                      hoverStyle: TextStyle(
                        color: context.appTheme.lyricsActiveLineColor,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                        decorationColor: context.appTheme.lyricsActiveLineColor,
                        shadows: [
                          Shadow(
                              blurRadius: 8,
                              color:
                                  context.appTheme.main.withValues(alpha: 0.9))
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 10),
              Icon(Icons.check_circle,
                  color: context.appTheme.iconColor(context.appTheme.button),
                  size: 20),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Single lyric line ────────────────────────────────────────────────────────

class _LyricLine extends StatefulWidget {
  final LyricLine line;
  final bool isActive;
  final Duration position;
  final bool isRtl;

  const _LyricLine({
    super.key,
    required this.line,
    required this.isActive,
    required this.position,
    required this.isRtl,
  });

  @override
  State<_LyricLine> createState() => _LyricLineState();
}

class _LyricLineState extends State<_LyricLine> {
  bool _hovered = false;

  static const _fallbackFonts = [
    'Malgun Gothic',
    'Noto Sans KR',
    'Noto Sans CJK',
    'Microsoft YaHei',
    'Segoe UI',
  ];

  void _seek(BuildContext context) {
    if (widget.line.start == Duration.zero) return;
    ProviderScope.containerOf(context, listen: false)
        .read(playerProvider.notifier)
        .seek(widget.line.start);
  }

  @override
  Widget build(BuildContext context) {
    final isSynced = widget.line.start != Duration.zero;
    final modernDesktop = context.appTheme.usesModernDesign;
    final dimColor = modernDesktop
        ? context.appTheme.lyricsInactiveLineColor
        : context.appTheme.text.withValues(alpha: 0.38);
    final baseColor = widget.isActive
        ? context.appTheme.lyricsActiveLineColor
        : _hovered && isSynced
            ? context.appTheme.lyricsActiveLineColor
            : dimColor;
    final fontSize = widget.isActive ? 22.0 : 18.0;
    final fontWeight = widget.isActive ? FontWeight.w700 : FontWeight.w500;

    // ── Karaoke word-by-word highlighting ──────────────────────────
    if (widget.isActive && widget.line.hasWordTiming) {
      return MouseRegion(
        cursor: isSynced ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => _seek(context),
          child: Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Align(
              alignment:
                  widget.isRtl ? Alignment.centerRight : Alignment.centerLeft,
              child: Wrap(
                textDirection:
                    widget.isRtl ? TextDirection.rtl : TextDirection.ltr,
                spacing: 0,
                runSpacing: 2,
                children: widget.line.words.map((word) {
                  final lit = widget.position >= word.start;
                  return AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 120),
                    style: TextStyle(
                      fontFamilyFallback: _fallbackFonts,
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      height: 1.35,
                      color: lit
                          ? (modernDesktop
                              ? context.appTheme.lyricsActiveLineColor
                              : context.appTheme.button)
                          : (modernDesktop
                              ? context.appTheme.lyricsInactiveLineColor
                              : context.appTheme.text.withValues(alpha: 0.55)),
                    ),
                    child: Text(
                      '${word.text} ',
                      textAlign:
                          widget.isRtl ? TextAlign.right : TextAlign.left,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      );
    }

    // ── Plain line (no word timing or not active) ───────────────────
    return MouseRegion(
      cursor: isSynced ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => _seek(context),
        child: Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            style: TextStyle(
              fontFamilyFallback: _fallbackFonts,
              fontSize: fontSize,
              fontWeight: fontWeight,
              height: 1.35,
              color: baseColor,
            ),
            child: Align(
              alignment:
                  widget.isRtl ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(
                widget.line.text,
                softWrap: true,
                textAlign: widget.isRtl ? TextAlign.right : TextAlign.left,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Placeholder ──────────────────────────────────────────────────────────────

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.appTheme.card,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_video,
              color: context.appTheme.subtext.withValues(alpha: 0.12),
              size: 72),
          SizedBox(height: 16),
          Text(
            'Play a song to\nsee the video',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appTheme.subtext, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
