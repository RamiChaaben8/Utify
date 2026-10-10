// ============================================================
// providers/cache_settings_provider.dart
// ============================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_cache_service.dart';
import '../services/ytmusic_feed_cache.dart';

const int kCacheLimit250MB = 250 * 1024 * 1024;
const int kCacheLimit500MB = 500 * 1024 * 1024;
const int kCacheLimit1GB = 1024 * 1024 * 1024;
const int kCacheLimit2GB = 2 * 1024 * 1024 * 1024;

class CacheSettingsState {
  final int totalBytes;
  final int limitBytes;
  final bool cacheOnMobileData;
  final bool isLoading;

  const CacheSettingsState({
    this.totalBytes = 0,
    this.limitBytes = kCacheLimit1GB,
    this.cacheOnMobileData = false,
    this.isLoading = true,
  });

  CacheSettingsState copyWith({
    int? totalBytes,
    int? limitBytes,
    bool? cacheOnMobileData,
    bool? isLoading,
  }) =>
      CacheSettingsState(
        totalBytes: totalBytes ?? this.totalBytes,
        limitBytes: limitBytes ?? this.limitBytes,
        cacheOnMobileData: cacheOnMobileData ?? this.cacheOnMobileData,
        isLoading: isLoading ?? this.isLoading,
      );
}

class CacheSettingsNotifier extends StateNotifier<CacheSettingsState> {
  StreamSubscription<int>? _sub;
  Timer? _timer;

  CacheSettingsNotifier() : super(const CacheSettingsState()) {
    _init();
  }

  Future<void> _init() async {
    final limit = await AudioCacheService.instance.limitBytes();
    final mobile = await AudioCacheService.instance.cacheOnMobileData();
    state = state.copyWith(
      limitBytes: limit,
      cacheOnMobileData: mobile,
      isLoading: false,
    );
    _sub = AudioCacheService.instance.sizeChanges.listen(_onSizeChanged);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshSize());
    unawaited(_refreshSize());
  }

  void _onSizeChanged(int bytes) {
    state = state.copyWith(totalBytes: bytes);
  }

  Future<void> _refreshSize() async {
    final audio = (await AudioCacheService.instance.stats()).totalBytes;
    final feeds = await YtMusicFeedCache.instance.totalBytes();
    state = state.copyWith(totalBytes: audio + feeds);
  }

  Future<void> setLimit(int bytes) async {
    await AudioCacheService.instance.setLimitBytes(bytes);
    state = state.copyWith(limitBytes: bytes);
    unawaited(_refreshSize());
  }

  Future<void> setCacheOnMobileData(bool value) async {
    await AudioCacheService.instance.setCacheOnMobileData(value);
    state = state.copyWith(cacheOnMobileData: value);
  }

  Future<void> clearCache() async {
    await AudioCacheService.instance.clear();
    await YtMusicFeedCache.instance.clear();
    await _refreshSize();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}

final cacheSettingsProvider =
    StateNotifierProvider.autoDispose<CacheSettingsNotifier, CacheSettingsState>(
  (ref) => CacheSettingsNotifier(),
);
