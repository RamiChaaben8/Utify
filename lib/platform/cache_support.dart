// ============================================================
// platform/cache_support.dart
//
// Single switch for the multi-layer caching system.
//
// The cache stack (audio file cache, prefetch, disk feed cache, lyrics
// cache, image cache tuning) ships as an Android-only feature. Desktop
// keeps its existing network-first behaviour untouched, so every layer
// gates on this one flag rather than scattering Platform.isAndroid
// checks through the services.
// ============================================================

import 'dart:io';

/// True where the caching system is active.
bool get cacheSystemEnabled => Platform.isAndroid;