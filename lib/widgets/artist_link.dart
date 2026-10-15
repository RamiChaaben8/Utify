// ============================================================
// widgets/artist_link.dart
//
// Makes an artist name tappable anywhere it is shown. Tapping resolves the
// artist's YouTube Music browse id (unless one is already known) and opens the
// artist page — through the desktop shell's navigation provider on Windows,
// or by pushing ArtistScreen on mobile.
// ============================================================

import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/shell/desktop_navigation.dart';
import '../models/artist_ref.dart';
import '../providers/ytmusic_home_provider.dart';
import '../screens/artist_screen.dart';

/// True when the app is rendering the desktop shell. Matches the switch in
/// `app.dart` (`Platform.isWindows ? DesktopShell : AppShell`).
bool get isDesktopShell => Platform.isWindows;

/// Opens the YouTube Music artist page for [browseId] on the current platform.
void openArtistPage(BuildContext context, WidgetRef ref, String browseId) {
  if (browseId.isEmpty) return;
  if (isDesktopShell) {
    // The shell listens to this and routes it through its normal history, so
    // the back/forward buttons keep working.
    ref.read(desktopYtArtistRequestProvider.notifier).state = browseId;
  } else {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ArtistScreen(browseId: browseId)),
    );
  }
}

/// A tappable artist name.
///
/// When [browseId] is supplied the page opens immediately; otherwise the name
/// is resolved through [artistIdByNameProvider] first (a cached mixed search).
class ArtistNameLink extends ConsumerStatefulWidget {
  const ArtistNameLink({
    super.key,
    required this.name,
    this.browseId,
    this.style,
    this.hoverStyle,
    this.maxLines = 1,
    this.textAlign,
    this.overflow = TextOverflow.ellipsis,
    this.enabled = true,
  });

  /// Artist display name to render and resolve.
  final String name;

  /// Known browse id — skips the lookup when provided.
  final String? browseId;

  final TextStyle? style;

  /// Style applied while hovered (desktop). Falls back to [style].
  final TextStyle? hoverStyle;

  final int? maxLines;
  final TextAlign? textAlign;
  final TextOverflow overflow;

  /// When false the name renders as plain, non-interactive text.
  final bool enabled;

  @override
  ConsumerState<ArtistNameLink> createState() => _ArtistNameLinkState();
}

class _ArtistNameLinkState extends ConsumerState<ArtistNameLink> {
  bool _hovered = false;
  bool _resolving = false;

  bool get _interactive => widget.enabled && widget.name.trim().isNotEmpty;

  Future<void> _open() async {
    if (_resolving) return;
    var id = widget.browseId;
    if (id == null || id.isEmpty) {
      _resolving = true;
      try {
        id = await ref.read(artistIdByNameProvider(widget.name).future);
      } catch (_) {
        id = null;
      } finally {
        _resolving = false;
      }
    }
    if (!mounted) return;
    if (id == null || id.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Could not find "${widget.name}"'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    openArtistPage(context, ref, id);
  }

  @override
  Widget build(BuildContext context) {
    final showHover = _interactive && _hovered && widget.hoverStyle != null;
    final text = Text(
      widget.name,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
      style: showHover ? widget.hoverStyle : widget.style,
    );

    if (!_interactive) return text;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _open,
        behavior: HitTestBehavior.opaque,
        child: text,
      ),
    );
  }
}

/// Renders one or more credited artists, each tappable.
///
/// A single artist (or a name-only fallback) delegates to [ArtistNameLink] and
/// keeps its hover styling. A collaboration is rendered as inline rich text
/// with one tap recognizer per name, so "Drake, Future" shows as two
/// independent links without ever splitting the underlying string by hand.
class ArtistNames extends ConsumerStatefulWidget {
  const ArtistNames({
    super.key,
    required this.refs,
    this.fallbackName,
    this.style,
    this.hoverStyle,
    this.separatorStyle,
    this.separator = ', ',
    this.maxLines = 1,
    this.textAlign,
    this.overflow = TextOverflow.ellipsis,
    this.enabled = true,
  });

  /// Per-artist references from the source.
  final List<ArtistRef> refs;

  /// Display name used when [refs] carries at most one artist (or is empty).
  final String? fallbackName;

  final TextStyle? style;

  /// Style applied to all names while hovered (desktop). Falls back to [style].
  final TextStyle? hoverStyle;

  /// Style for the separator between names. Falls back to [style].
  final TextStyle? separatorStyle;

  final String separator;
  final int? maxLines;
  final TextAlign? textAlign;
  final TextOverflow overflow;

  /// When false the names render as plain, non-interactive text.
  final bool enabled;

  @override
  ConsumerState<ArtistNames> createState() => _ArtistNamesState();
}

class _ArtistNamesState extends ConsumerState<ArtistNames> {
  final List<TapGestureRecognizer> _recognizers = [];
  bool _hovered = false;
  bool _resolving = false;

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  /// Keeps one recognizer per artist alive across rebuilds. Parents like the
  /// player bar rebuild often (position ticks), and disposing a recognizer
  /// while a pointer is down would assert — so reuse by index instead.
  void _syncRecognizers(List<ArtistRef> artists) {
    while (_recognizers.length < artists.length) {
      _recognizers.add(TapGestureRecognizer());
    }
    while (_recognizers.length > artists.length) {
      _recognizers.removeLast().dispose();
    }
    for (var i = 0; i < artists.length; i++) {
      final artist = artists[i];
      _recognizers[i].onTap = () => _open(artist);
    }
  }

  /// The references to actually render. Collapses to a single name when the
  /// source gave us no collaboration structure.
  List<ArtistRef> get _display {
    final refs = widget.refs;
    final fallback = widget.fallbackName?.trim() ?? '';
    if (refs.length <= 1) {
      if (refs.isEmpty) {
        return fallback.isEmpty ? const [] : [ArtistRef(name: fallback)];
      }
      final only = refs.first;
      if (fallback.isNotEmpty && fallback != only.name) {
        return [ArtistRef(name: fallback, browseId: only.browseId)];
      }
      return [only];
    }
    return refs;
  }

  Future<void> _open(ArtistRef artist) async {
    if (_resolving) return;
    var id = artist.browseId;
    if (id == null || id.isEmpty) {
      _resolving = true;
      try {
        id = await ref.read(artistIdByNameProvider(artist.name).future);
      } catch (_) {
        id = null;
      } finally {
        _resolving = false;
      }
    }
    if (!mounted) return;
    if (id == null || id.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Could not find "${artist.name}"'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    openArtistPage(context, ref, id);
  }

  @override
  Widget build(BuildContext context) {
    final display = _display;
    if (display.length <= 1) {
      final only = display.isEmpty ? null : display.first;
      return ArtistNameLink(
        name: only?.name ?? '',
        browseId: only?.browseId,
        style: widget.style,
        hoverStyle: widget.hoverStyle,
        maxLines: widget.maxLines,
        textAlign: widget.textAlign,
        overflow: widget.overflow,
        enabled: widget.enabled,
      );
    }
    return _buildRich(context, display);
  }

  Widget _buildRich(BuildContext context, List<ArtistRef> artists) {
    if (widget.enabled) _syncRecognizers(artists);

    final baseStyle = widget.style ?? DefaultTextStyle.of(context).style;
    final nameStyle = (_hovered && widget.hoverStyle != null)
        ? widget.hoverStyle!
        : baseStyle;
    final sepStyle = widget.separatorStyle ?? baseStyle;

    final spans = <InlineSpan>[];
    for (var i = 0; i < artists.length; i++) {
      if (i > 0) {
        spans.add(TextSpan(text: widget.separator, style: sepStyle));
      }
      final artist = artists[i];
      spans.add(TextSpan(
        text: artist.name,
        style: nameStyle,
        recognizer: widget.enabled ? _recognizers[i] : null,
      ));
    }

    final rich = Text.rich(
      TextSpan(children: spans),
      style: baseStyle,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign ?? TextAlign.start,
    );

    if (!widget.enabled) return rich;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (widget.hoverStyle != null && !_hovered) {
          setState(() => _hovered = true);
        }
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: rich,
    );
  }
}
