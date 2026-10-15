// ============================================================
// desktop/player/desktop_player_bar.dart
// Bottom 80px player bar with progress, controls, and volume.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/song.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/panel_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/song_context_menu.dart';
import '../../widgets/artist_link.dart';
import '../../widgets/device_picker.dart';
import '../theme/desktop_theme.dart';
import '../../widgets/listen_party_controls.dart';

class DesktopPlayerBar extends ConsumerStatefulWidget {
  const DesktopPlayerBar({super.key});

  @override
  ConsumerState<DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<DesktopPlayerBar> {
  double _volume = 0.8;
  double _volumeBeforeMute = 0.8;
  bool _muted = false;
  bool _draggingProgress = false;
  double _dragProgress = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = ref.read(audioHandlerProvider).service;
      setState(() => _volume = service.volume);
      _applyVolume(_volume);
    });
  }

  void _applyVolume(double v) {
    try {
      ref.read(audioHandlerProvider).service.setVolume(v);
    } catch (_) {}
  }

  void _toggleMute() {
    setState(() {
      if (_muted) {
        _muted = false;
        _volume = _volumeBeforeMute;
        _applyVolume(_volume);
      } else {
        _volumeBeforeMute = _volume;
        _muted = true;
        _applyVolume(0.0);
      }
    });
  }

  void _togglePanel(PanelMode mode) {
    final current = ref.read(panelModeProvider);
    final next = current == mode ? PanelMode.none : mode;
    ref.read(panelModeProvider.notifier).state = next;

    // Pre-fetch lyrics when panel is opened
    if (next == PanelMode.lyrics) {
      final song = ref.read(playerProvider).currentSong;
      if (song != null) {
        ref.read(lyricsProvider.notifier).fetchFor(song.id, song: song);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(playerProvider);
    final panelMode = ref.watch(panelModeProvider);
    final song = ps.currentSong;

    final position = ps.position;
    final duration = ps.duration;
    final progressFraction = (duration.inMilliseconds > 0 && !_draggingProgress)
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : (_draggingProgress ? _dragProgress : 0.0);
    final layout = context.appTheme.layout;
    final skin = _PlayerBarSkin.of(context);

    return Container(
      height: skin.barHeight,
      decoration: BoxDecoration(
        color: skin.barBackground,
        borderRadius: context.appTheme.usesModernDesign
            ? BorderRadius.only(
                topLeft: Radius.circular(layout.panelRadius),
                topRight: Radius.circular(layout.panelRadius),
              )
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Progress bar ──────────────────────────────────────────────
          _ProgressBar(
            skin: skin,
            fraction: progressFraction,
            position: position,
            duration: duration,
            onSeek: (fraction) {
              final target = Duration(
                  milliseconds: (fraction * duration.inMilliseconds).toInt());
              ref.read(playerProvider.notifier).seek(target);
            },
            onDragStart: (f) => setState(() {
              _draggingProgress = true;
              _dragProgress = f;
            }),
            onDragUpdate: (f) => setState(() => _dragProgress = f),
            onDragEnd: (f) {
              setState(() => _draggingProgress = false);
              final target =
                  Duration(milliseconds: (f * duration.inMilliseconds).toInt());
              ref.read(playerProvider.notifier).seek(target);
            },
          ),

          // ── Controls row ──────────────────────────────────────────────
          SizedBox(
            height: skin.controlsHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // Left: song info
                  Expanded(child: _SongInfo(song: song)),

                  // Center: transport controls
                  Expanded(
                    child: _TransportControls(
                      skin: skin,
                      isPlaying: ps.isPlaying,
                      isLoading: ps.isLoading,
                      shuffle: ps.shuffle,
                      loopMode: ps.loopMode,
                      onPlayPause: () =>
                          ref.read(playerProvider.notifier).togglePlayPause(),
                      onPrev: () =>
                          ref.read(playerProvider.notifier).skipToPrevious(),
                      onNext: () =>
                          ref.read(playerProvider.notifier).skipToNext(),
                      onShuffle: () =>
                          ref.read(playerProvider.notifier).toggleShuffle(),
                      onRepeat: () =>
                          ref.read(playerProvider.notifier).toggleLoopMode(),
                    ),
                  ),

                  // Right: volume + panel controls
                  Expanded(
                    child: _VolumeControls(
                      skin: skin,
                      volume: _muted ? 0.0 : _volume,
                      muted: _muted,
                      panelMode: panelMode,
                      onVolumeChanged: (v) {
                        setState(() {
                          _volume = v;
                          _muted = v < 0.01;
                          if (!_muted) _volumeBeforeMute = v;
                        });
                        _applyVolume(v);
                      },
                      onMuteToggle: _toggleMute,
                      onLyricsToggle: () => _togglePanel(PanelMode.lyrics),
                      onQueueToggle: () => _togglePanel(PanelMode.queue),
                    ),
                  ),
                  // The listen-party entry point is a headphones icon, which
                  // the reference layout does not have.
                  if (skin.showListenParty) const ListenPartyControls(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Player bar skin ───────────────────────────────────────────────────────────

/// Narrowest the volume slider is allowed to get before it is dropped entirely
/// and only the speaker icon remains.
const double kMinSliderWidth = 64;

/// Visual configuration for the player bar.
///
/// [modern] is the flatter, Spotify-like treatment that every desktop theme now
/// uses; [classic] is the original look, kept as a fallback for non-desktop
/// layouts. The rest of the bar reads from here so there is a single layout code
/// path.
class _PlayerBarSkin {
  final Color barBackground;
  final Color accent;
  final Color onAccent;

  /// Prev / next glyphs, which read brighter than the secondary glyphs.
  final Color primaryIcon;
  final Color secondaryIcon;
  final Color sideIcon;
  final Color activeIcon;
  final Color hoverIcon;

  final Color sliderTrack;

  final double barHeight;
  final double controlsHeight;
  final double playSize;
  final double playGlyphSize;
  final double transportIconSize;
  final double transportGap;
  final double sideIconSize;
  final double sideGap;

  /// Padding around each bare icon. Keeps a usable click target without
  /// drawing a plate, and controls how wide the right-hand cluster ends up.
  final double iconPadding;
  final double sliderWidth;
  final double sliderTrackHeight;

  /// 0 keeps the thumb hidden until the slider is hovered.
  final double sliderThumbRadius;

  final IconData lyricsIcon;
  final IconData queueIcon;
  final IconData deviceIcon;
  final IconData miniPlayerIcon;
  final IconData fullscreenIcon;
  final bool showListenParty;

  /// The mini-player and fullscreen glyphs are Verdant Night additions; the
  /// reference layout for this skin leaves them out.
  final bool showMiniPlayer;
  final bool showFullscreen;

  const _PlayerBarSkin({
    required this.barBackground,
    required this.accent,
    required this.onAccent,
    required this.primaryIcon,
    required this.secondaryIcon,
    required this.sideIcon,
    required this.activeIcon,
    required this.hoverIcon,
    required this.sliderTrack,
    required this.barHeight,
    required this.controlsHeight,
    required this.playSize,
    required this.playGlyphSize,
    required this.transportIconSize,
    required this.transportGap,
    required this.sideIconSize,
    required this.sideGap,
    required this.iconPadding,
    required this.sliderWidth,
    required this.sliderTrackHeight,
    required this.sliderThumbRadius,
    required this.lyricsIcon,
    required this.queueIcon,
    required this.deviceIcon,
    required this.miniPlayerIcon,
    required this.fullscreenIcon,
    required this.showListenParty,
    required this.showMiniPlayer,
    required this.showFullscreen,
  });

  factory _PlayerBarSkin.of(BuildContext context) {
    final t = context.appTheme;
    return t.usesModernDesign
        ? _PlayerBarSkin.modern(t)
        : _PlayerBarSkin.classic(t);
  }

  /// Flat dark bar, small filled play button, slim outline glyphs.
  ///
  /// Every colour is read from the theme instead of being a literal: the old
  /// literals were near-misses (`#7DC143` vs the theme's `#7FD13B`, `#202020`
  /// vs `#1C1C1C`), which split the lime down the middle of the screen and left
  /// the bar matching no panel in the app.
  factory _PlayerBarSkin.modern(AppThemeData t) {
    final layout = t.layout;
    return _PlayerBarSkin(
      barBackground: t.player,
      accent: t.nowPlayingAccent,
      onAccent: t.onButtonFill,
      primaryIcon: t.subtext,
      secondaryIcon: t.subtext,
      sideIcon: t.subtext,
      activeIcon: t.nowPlayingAccent,
      hoverIcon: t.iconHover,
      sliderTrack: t.shadow,
      barHeight: layout.playerBarHeight,
      controlsHeight: layout.playerControlsHeight,
      playSize: layout.playButtonSize,
      playGlyphSize: 30,
      transportIconSize: 22,
      transportGap: 18,
      sideIconSize: 22,
      sideGap: 4,
      iconPadding: 5,
      sliderWidth: 110,
      sliderTrackHeight: 4,
      sliderThumbRadius: 8,
      lyricsIcon: Icons.mic_none,
      queueIcon: Icons.format_list_bulleted,
      deviceIcon: Icons.smartphone_outlined,
      miniPlayerIcon: Icons.picture_in_picture_alt_outlined,
      fullscreenIcon: Icons.fullscreen_outlined,
      showListenParty: false,
      showMiniPlayer: false,
      showFullscreen: false,
    );
  }

  /// The original look, driven entirely by the active theme's tokens.
  factory _PlayerBarSkin.classic(AppThemeData t) {
    final layout = t.layout;
    return _PlayerBarSkin(
      barBackground: t.player,
      accent: t.button,
      onAccent: t.playIconColor,
      primaryIcon: t.iconColor(t.text),
      secondaryIcon: t.iconColor(t.subtext),
      sideIcon: t.iconColor(t.subtext),
      activeIcon: t.iconColor(t.button, hovered: true),
      hoverIcon: t.iconColor(t.text),
      sliderTrack: t.shadow,
      barHeight: layout.playerBarHeight,
      controlsHeight: layout.playerControlsHeight,
      playSize: layout.playButtonSize,
      playGlyphSize: 28,
      transportIconSize: 20,
      transportGap: 4,
      sideIconSize: 20,
      sideGap: 0,
      iconPadding: 6,
      sliderWidth: 80,
      sliderTrackHeight: 3,
      sliderThumbRadius: 5,
      lyricsIcon: Icons.lyrics_outlined,
      queueIcon: Icons.queue_music_outlined,
      deviceIcon: Icons.cast,
      miniPlayerIcon: Icons.picture_in_picture_alt_outlined,
      fullscreenIcon: Icons.fullscreen_outlined,
      showListenParty: true,
      showMiniPlayer: false,
      showFullscreen: true,
    );
  }
}

// ─── Progress bar ─────────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  final _PlayerBarSkin skin;
  final double fraction;
  final Duration position;
  final Duration duration;
  final void Function(double) onSeek;
  final void Function(double) onDragStart;
  final void Function(double) onDragUpdate;
  final void Function(double) onDragEnd;

  const _ProgressBar({
    required this.skin,
    required this.fraction,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final layout = context.appTheme.layout;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: layout.progressRowPadding),
      child: Row(
        children: [
          Text(
            _fmt(position),
            style: TextStyle(color: context.appTheme.subtext, fontSize: 11),
          ),
          SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    final f = (d.localPosition.dx / constraints.maxWidth)
                        .clamp(0.0, 1.0);
                    onSeek(f);
                  },
                  onHorizontalDragStart: (d) {
                    final f = (d.localPosition.dx / constraints.maxWidth)
                        .clamp(0.0, 1.0);
                    onDragStart(f);
                  },
                  onHorizontalDragUpdate: (d) {
                    final f = (d.localPosition.dx / constraints.maxWidth)
                        .clamp(0.0, 1.0);
                    onDragUpdate(f);
                  },
                  onHorizontalDragEnd: (_) => onDragEnd(fraction),
                  child: SizedBox(
                    height: 16,
                    child: Center(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(
                            height: layout.progressTrackHeight,
                            decoration: BoxDecoration(
                              color: skin.sliderTrack,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: fraction,
                            child: Container(
                              height: layout.progressTrackHeight,
                              decoration: BoxDecoration(
                                color: skin.accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(width: 8),
          Text(
            _fmt(duration),
            style: TextStyle(color: context.appTheme.subtext, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ─── Song info (left 1/3) ─────────────────────────────────────────────────────

class _SongInfo extends ConsumerWidget {
  final Song? song;
  const _SongInfo({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (song == null) return SizedBox.shrink();

    final s = song!;
    final ps = ref.watch(playerProvider);
    final queue = ps.queue;
    final idx = ps.currentIndex;
    final next =
        (queue.length > 1 && idx >= 0) ? queue[(idx + 1) % queue.length] : null;

    return SongContextMenu(
      song: s,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: s.thumbnailUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: s.thumbnailUrl,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                        width: 48, height: 48, color: context.appTheme.card),
                    errorWidget: (_, __, ___) => Container(
                      width: 48,
                      height: 48,
                      color: context.appTheme.card,
                      child: Icon(Icons.music_note,
                          color:
                              context.appTheme.subtext.withValues(alpha: 0.54),
                          size: 20),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    color: context.appTheme.card,
                    child: Icon(Icons.music_note,
                        color: context.appTheme.subtext.withValues(alpha: 0.54),
                        size: 20),
                  ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appTheme.text,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 2),
                ArtistNames(
                  refs: s.artistRefs,
                  fallbackName: s.channelName,
                  maxLines: 1,
                  style:
                      TextStyle(color: context.appTheme.subtext, fontSize: 11),
                  hoverStyle: TextStyle(
                      color: context.appTheme.text,
                      fontSize: 11,
                      decoration: TextDecoration.underline,
                      decorationColor: context.appTheme.text),
                ),
              ],
            ),
          ),
          SongMenuButton(song: s, size: 16),
          if (next != null) ...[
            SizedBox(width: 8),
            Container(
                width: 1, height: 36, color: context.appTheme.dividerColor),
            SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: next.thumbnailUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: next.thumbnailUrl,
                      width: 30,
                      height: 30,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                          width: 30, height: 30, color: context.appTheme.card),
                      errorWidget: (_, __, ___) => Container(
                        width: 30,
                        height: 30,
                        color: context.appTheme.card,
                        child: Icon(Icons.music_note,
                            color: context.appTheme.subtext
                                .withValues(alpha: 0.54),
                            size: 12),
                      ),
                    )
                  : Container(
                      width: 30,
                      height: 30,
                      color: context.appTheme.card,
                      child: Icon(Icons.music_note,
                          color:
                              context.appTheme.subtext.withValues(alpha: 0.54),
                          size: 12),
                    ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Next',
                    style: TextStyle(
                      color: context.appTheme.nowPlayingAccent,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    next.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Secondary copy — the `Next` label above it already owns
                    // the accent, so this was the second lime line in a row.
                    style: TextStyle(
                      color: context.appTheme.subtext,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  ArtistNames(
                    refs: next.artistRefs,
                    fallbackName: next.channelName,
                    maxLines: 1,
                    style: TextStyle(
                        color: context.appTheme.subtext, fontSize: 10),
                    hoverStyle: TextStyle(
                        color: context.appTheme.text,
                        fontSize: 10,
                        decoration: TextDecoration.underline,
                        decorationColor: context.appTheme.text),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Transport controls (center 1/3) ─────────────────────────────────────────

class _TransportControls extends StatelessWidget {
  final _PlayerBarSkin skin;
  final bool isPlaying;
  final bool isLoading;
  final bool shuffle;
  final LoopMode loopMode;
  final VoidCallback onPlayPause;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onShuffle;
  final VoidCallback onRepeat;

  const _TransportControls({
    required this.skin,
    required this.isPlaying,
    required this.isLoading,
    required this.shuffle,
    required this.loopMode,
    required this.onPlayPause,
    required this.onPrev,
    required this.onNext,
    required this.onShuffle,
    required this.onRepeat,
  });

  @override
  Widget build(BuildContext context) {
    final repeatIcon =
        loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat;
    final repeatColor =
        loopMode != LoopMode.off ? skin.activeIcon : skin.secondaryIcon;

    final playButton = Material(
      color: skin.accent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlayPause,
        child: SizedBox(
          width: skin.playSize,
          height: skin.playSize,
          child: Center(
            child: isLoading
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                        color: skin.onAccent, strokeWidth: 2),
                  )
                : Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: skin.onAccent,
                    size: skin.playGlyphSize,
                  ),
          ),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // The five buttons keep their size; the spacing around them absorbs
        // any shortfall so a narrow center slot never overflows.
        final iconBox = skin.transportIconSize + skin.iconPadding * 2;
        final buttons = 4 * iconBox + skin.playSize;
        final gap = ((constraints.maxWidth - buttons) / 4)
            .clamp(0.0, skin.transportGap);

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SkinIconButton(
              icon: Icons.shuffle,
              padding: skin.iconPadding,
              size: skin.transportIconSize,
              color: shuffle ? skin.activeIcon : skin.secondaryIcon,
              hoverColor: skin.hoverIcon,
              onPressed: onShuffle,
            ),
            SizedBox(width: gap),
            _SkinIconButton(
              icon: Icons.skip_previous,
              padding: skin.iconPadding,
              size: skin.transportIconSize,
              color: skin.primaryIcon,
              hoverColor: skin.hoverIcon,
              onPressed: onPrev,
            ),
            SizedBox(width: gap),
            playButton,
            SizedBox(width: gap),
            _SkinIconButton(
              icon: Icons.skip_next,
              padding: skin.iconPadding,
              size: skin.transportIconSize,
              color: skin.primaryIcon,
              hoverColor: skin.hoverIcon,
              onPressed: onNext,
            ),
            SizedBox(width: gap),
            _SkinIconButton(
              icon: repeatIcon,
              padding: skin.iconPadding,
              size: skin.transportIconSize,
              color: repeatColor,
              hoverColor: skin.hoverIcon,
              onPressed: onRepeat,
            ),
          ],
        );
      },
    );
  }
}

/// Borderless transport glyph that lightens to [hoverColor] on hover.
class _SkinIconButton extends StatefulWidget {
  final IconData icon;
  final double size;
  final double padding;
  final Color color;
  final Color hoverColor;
  final VoidCallback onPressed;
  final String? tooltip;

  const _SkinIconButton({
    required this.icon,
    required this.size,
    required this.padding,
    required this.color,
    required this.hoverColor,
    required this.onPressed,
    this.tooltip,
  });

  @override
  State<_SkinIconButton> createState() => _SkinIconButtonState();
}

class _SkinIconButtonState extends State<_SkinIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Padding(
          // Keeps a comfortable click target without adding a visible plate.
          padding: EdgeInsets.all(widget.padding),
          child: Icon(
            widget.icon,
            size: widget.size,
            color: _hovered ? widget.hoverColor : widget.color,
          ),
        ),
      ),
    );

    if (widget.tooltip == null) return button;
    return Tooltip(message: widget.tooltip!, child: button);
  }
}

// ─── Volume controls (right 1/3) ─────────────────────────────────────────────

class _VolumeControls extends StatelessWidget {
  final _PlayerBarSkin skin;
  final double volume;
  final bool muted;
  final PanelMode panelMode;
  final void Function(double) onVolumeChanged;
  final VoidCallback onMuteToggle;
  final VoidCallback onLyricsToggle;
  final VoidCallback onQueueToggle;

  const _VolumeControls({
    required this.skin,
    required this.volume,
    required this.muted,
    required this.panelMode,
    required this.onVolumeChanged,
    required this.onMuteToggle,
    required this.onLyricsToggle,
    required this.onQueueToggle,
  });

  @override
  Widget build(BuildContext context) {
    final IconData volIcon = muted || volume < 0.01
        ? Icons.volume_off_outlined
        : volume < 0.5
            ? Icons.volume_down_outlined
            : Icons.volume_up_outlined;

    // Lyrics, queue, device, volume, mini player, fullscreen.
    final gap = SizedBox(width: skin.sideGap);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The glyphs have a fixed cost; the slider absorbs whatever is left so
        // a narrow window shrinks the slider instead of overflowing the row.
        final slot = constraints.maxWidth;
        final iconCount =
            3 + (skin.showMiniPlayer ? 1 : 0) + (skin.showFullscreen ? 1 : 0);
        final iconBox = skin.sideIconSize + skin.iconPadding * 2;
        final deviceBox = skin.sideIconSize + 16;
        // Gaps: one after the device button, one between each glyph, plus one
        // more when the slider is squeezed in.
        final fixed =
            deviceBox + iconCount * iconBox + iconCount * skin.sideGap;
        final room = slot - fixed;
        final showSlider = room >= kMinSliderWidth;
        final sliderWidth = room.clamp(kMinSliderWidth, skin.sliderWidth);

        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: 'Connect to a device',
              child: DevicePickerButton(
                  size: skin.sideIconSize, icon: skin.deviceIcon),
            ),

            gap,

            // Lyrics button — opens fullscreen lyrics overlay
            _SkinIconButton(
              icon: skin.lyricsIcon,
              padding: skin.iconPadding,
              size: skin.sideIconSize,
              color: panelMode == PanelMode.lyrics
                  ? skin.activeIcon
                  : skin.sideIcon,
              hoverColor: skin.hoverIcon,
              tooltip: panelMode == PanelMode.lyrics
                  ? 'Close Fullscreen Lyrics'
                  : 'Fullscreen Lyrics',
              onPressed: onLyricsToggle,
            ),

            gap,

            // Queue button
            _SkinIconButton(
              icon: skin.queueIcon,
              padding: skin.iconPadding,
              size: skin.sideIconSize,
              color: panelMode == PanelMode.queue
                  ? skin.activeIcon
                  : skin.sideIcon,
              hoverColor: skin.hoverIcon,
              tooltip: panelMode == PanelMode.queue ? 'Close Queue' : 'Queue',
              onPressed: onQueueToggle,
            ),

            gap,

            // Mute button
            _SkinIconButton(
              icon: volIcon,
              padding: skin.iconPadding,
              size: skin.sideIconSize,
              color: skin.sideIcon,
              hoverColor: skin.hoverIcon,
              tooltip: muted ? 'Unmute' : 'Mute',
              onPressed: onMuteToggle,
            ),

            if (showSlider) ...[
              gap,

              // Volume slider — thumb only appears while hovered.
              _HoverRevealSlider(
                width: sliderWidth,
                trackHeight: skin.sliderTrackHeight,
                thumbRadius: skin.sliderThumbRadius,
                activeColor: skin.accent,
                inactiveColor: skin.sliderTrack,
                thumbColor: skin.onAccent,
                value: volume,
                onChanged: onVolumeChanged,
              ),
            ],

            // Mini player / picture-in-picture.
            if (skin.showMiniPlayer) ...[
              gap,
              _SkinIconButton(
                icon: skin.miniPlayerIcon,
                padding: skin.iconPadding,
                size: skin.sideIconSize,
                color: skin.sideIcon,
                hoverColor: skin.hoverIcon,
                tooltip: 'Mini player',
                onPressed: () {},
              ),
            ],

            // Fullscreen placeholder
            if (skin.showFullscreen) ...[
              gap,
              _SkinIconButton(
                icon: skin.fullscreenIcon,
                padding: skin.iconPadding,
                size: skin.sideIconSize,
                color: skin.sideIcon,
                hoverColor: skin.hoverIcon,
                onPressed: () {},
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Slider whose thumb is invisible until the pointer is over it.
class _HoverRevealSlider extends StatefulWidget {
  final double width;
  final double trackHeight;
  final double thumbRadius;
  final Color activeColor;
  final Color inactiveColor;

  /// Colour of the revealed thumb. Defaults to the inherited
  /// `SliderThemeData.thumbColor`, which is `theme.text` — the same lime as
  /// the active track in Verdant Night, i.e. an invisible thumb on hover.
  final Color? thumbColor;
  final double value;
  final ValueChanged<double> onChanged;

  const _HoverRevealSlider({
    required this.width,
    required this.trackHeight,
    required this.thumbRadius,
    required this.activeColor,
    required this.inactiveColor,
    this.thumbColor,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_HoverRevealSlider> createState() => _HoverRevealSliderState();
}

class _HoverRevealSliderState extends State<_HoverRevealSlider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: widget.width,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: widget.activeColor,
            inactiveTrackColor: widget.inactiveColor,
            thumbColor: widget.thumbColor,
            trackHeight: widget.trackHeight,
            // Collapsing the radius to zero hides the thumb entirely.
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: _hovered ? widget.thumbRadius : 0,
              elevation: 0,
              pressedElevation: 0,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
            overlayColor: Colors.transparent,
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: widget.value,
            min: 0.0,
            max: 1.0,
            onChanged: widget.onChanged,
          ),
        ),
      ),
    );
  }
}
