// ============================================================
// widgets/horizontal_song_card.dart
//
// Compact vertical card for horizontal scroll lists (Home screen).
// Shows thumbnail + title + channel.
// ============================================================

import 'package:flutter/material.dart';

import '../models/song.dart';
import 'app_thumbnail.dart';

class HorizontalSongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const HorizontalSongCard({super.key, required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            AppThumbnail(
              imageUrl: song.thumbnailUrl,
              videoId: song.id,
              width: 130,
              height: 100,
              borderRadius: 8,
              backgroundColor: const Color(0xFF282828),
            ),
            const SizedBox(height: 6),
            // Title
            Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.channelName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB3B3B3), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
