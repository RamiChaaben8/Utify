// ============================================================
// providers/youtube_provider.dart
//
// Provides the YoutubeService singleton and a search state.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/youtube_service.dart';
import '../services/ytmusic_service.dart';
import '../services/playlist_import_service.dart';
import 'ytmusic_home_provider.dart';

// Singleton YoutubeService
final youtubeServiceProvider = Provider<YoutubeService>((ref) {
  final service = YoutubeService();
  ref.onDispose(service.dispose);
  return service;
});

final playlistImportServiceProvider = Provider<PlaylistImportService>((ref) {
  return PlaylistImportService(ref.watch(youtubeServiceProvider));
});

// ─── Search state ────────────────────────────────────────────────────────────

class SearchState {
  final List<Song> results;
  final bool isLoading;
  final String? error;
  final String query;

  const SearchState({
    this.results = const [],
    this.isLoading = false,
    this.error,
    this.query = '',
  });

  SearchState copyWith({
    List<Song>? results,
    bool? isLoading,
    String? error,
    String? query,
    bool clearError = false,
  }) {
    return SearchState(
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      query: query ?? this.query,
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final YoutubeService _youtube;
  final YtMusicService _music;
  int _requestId = 0;

  SearchNotifier(this._youtube, this._music) : super(const SearchState());

  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      state = const SearchState();
      return;
    }

    final requestId = ++_requestId;
    _youtube.clearPrefetchQueue();
    state = state.copyWith(isLoading: true, query: query, clearError: true);

    try {
      // Search the YouTube Music catalogue (Innertube) — the same source the
      // home feed uses — instead of scraping the YouTube results page. The
      // `youtube_explode_dart` search parser throws on live-stream results
      // (a bad `int.parse` on the "Streamed …" timestamp and a dynamic
      // extension call), which aborted whole searches.
      final songs = await _music.searchSongs(query, curated: false);
      if (requestId != _requestId) return;
      final results = [for (final s in songs) s.toSong()];
      state = state.copyWith(results: results, isLoading: false);

      // Immediately start resolving stream URLs for the top results in the
      // background. By the time the user taps a song the manifest is already
      // cached, so playback starts without waiting for a network round-trip.
      // maxConcurrent=4 avoids hammering YouTube and triggering rate-limits.
      _youtube.prefetchBatch(
        results.take(6).map((s) => s.id).toList(),
        maxConcurrent: 4,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        isLoading: false,
        error: 'An unexpected error occurred. Check your connection.',
      );
    }
  }

  void clear() {
    _requestId++;
    _youtube.clearPrefetchQueue();
    state = const SearchState();
  }
}

final searchProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  return SearchNotifier(
    ref.watch(youtubeServiceProvider),
    ref.watch(ytMusicServiceProvider),
  );
});
