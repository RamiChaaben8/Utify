import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/thumbnail_url.dart';

/// Reusable image widget for song/video/album thumbnails across mobile and desktop.
///
/// Handles:
/// - URL normalization (http -> https, // -> https:, size adjustment)
/// - Fallback chaining for video thumbnails (hqdefault -> mqdefault)
/// - Placeholder shimmer / container
/// - Error handling with music note placeholder
/// - Smooth fade-in
class AppThumbnail extends StatefulWidget {
  final String? imageUrl;
  final String? videoId;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;
  final IconData placeholderIcon;
  final Color? backgroundColor;

  const AppThumbnail({
    super.key,
    required this.imageUrl,
    this.videoId,
    this.width,
    this.height,
    this.borderRadius = 8.0,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.placeholderIcon = Icons.music_note,
    this.backgroundColor,
  });

  @override
  State<AppThumbnail> createState() => _AppThumbnailState();
}

class _AppThumbnailState extends State<AppThumbnail> {
  int _fallbackIndex = 0;
  List<String> _candidateUrls = [];

  @override
  void initState() {
    super.initState();
    _buildCandidateUrls();
  }

  @override
  void didUpdateWidget(covariant AppThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl || oldWidget.videoId != widget.videoId) {
      _fallbackIndex = 0;
      _buildCandidateUrls();
    }
  }

  void _buildCandidateUrls() {
    final list = <String>[];
    final normalized = ThumbnailUrl.normalize(widget.imageUrl, videoId: widget.videoId);
    if (normalized.isNotEmpty) {
      list.add(normalized);
    }
    if (widget.videoId != null && widget.videoId!.trim().isNotEmpty) {
      for (final fb in ThumbnailUrl.videoFallbacks(widget.videoId!)) {
        if (!list.contains(fb)) {
          list.add(fb);
        }
      }
    }
    _candidateUrls = list;
  }

  void _handleError(Object error, StackTrace? stackTrace) {
    if (kDebugMode) {
      final currentUrl = _candidateUrls.isNotEmpty && _fallbackIndex < _candidateUrls.length
          ? _candidateUrls[_fallbackIndex]
          : widget.imageUrl;
      debugPrint('[AppThumbnail] Failed to load "$currentUrl": $error');
    }
    if (mounted && _fallbackIndex < _candidateUrls.length - 1) {
      setState(() {
        _fallbackIndex++;
      });
    }
  }

  Widget _defaultPlaceholder(BuildContext context) {
    final bg = widget.backgroundColor ?? const Color(0xFF1A1A1A);
    return Container(
      width: widget.width,
      height: widget.height,
      color: bg,
      child: Center(
        child: Icon(
          widget.placeholderIcon,
          color: const Color(0xFF3A3A3A),
          size: widget.width != null ? (widget.width! * 0.35).clamp(16.0, 48.0) : 24.0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveUrl = _candidateUrls.isNotEmpty && _fallbackIndex < _candidateUrls.length
        ? _candidateUrls[_fallbackIndex]
        : '';

    final placeholder = widget.placeholder ?? _defaultPlaceholder(context);
    final errorWidget = widget.errorWidget ?? _defaultPlaceholder(context);

    if (effectiveUrl.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: errorWidget,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: CachedNetworkImage(
          imageUrl: effectiveUrl,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          fadeInDuration: const Duration(milliseconds: 200),
          fadeOutDuration: const Duration(milliseconds: 150),
          placeholder: (_, __) => placeholder,
          errorWidget: (ctx, url, err) {
            _handleError(err, null);
            return errorWidget;
          },
        ),
      ),
    );
  }
}
