// ============================================================
// widgets/video_preview_widget.dart
//
// Static artwork used in the now-playing views. Keeping this as an image
// avoids decoding and rendering a second, muted video stream beside audio.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/artwork_cache_manager.dart';

class VideoPreviewWidget extends StatelessWidget {
  final String imageUrl;
  final BoxFit fit;

  const VideoPreviewWidget({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    final image = imageUrl.trim();
    final placeholder = ColoredBox(
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Icon(
          Icons.music_note,
          color: Colors.white.withValues(alpha: 0.35),
          size: 48,
        ),
      ),
    );

    if (image.isEmpty) return _sized(placeholder);

    return _sized(
      CachedNetworkImage(
        imageUrl: image,
        cacheManager: ArtworkCacheManager.instance,
        fit: fit,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }

  Widget _sized(Widget child) {
    if (fit == BoxFit.cover) {
      return SizedBox.expand(child: child);
    }
    return Container(
      width: double.infinity,
      height: 320,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
