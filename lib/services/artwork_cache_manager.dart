// ============================================================
// services/artwork_cache_manager.dart
//
// Custom CacheManager for cached_network_image.
// ============================================================

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared cache manager for album/thumbnail artwork.
///
/// Limits: at most 500 objects on disk, stale after 30 days. The memory cache
/// is handled by Flutter's image cache; these settings control the persistent
/// disk cache only.
class ArtworkCacheManager {
  static final CacheManager instance = CacheManager(
    Config(
      'utify_artwork_cache',
      maxNrOfCacheObjects: 500,
      stalePeriod: const Duration(days: 30),
      repo: JsonCacheInfoRepository(databaseName: 'utify_artwork_cache.db'),
      fileService: HttpFileService(),
    ),
  );
}
