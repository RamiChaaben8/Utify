// lib/providers/ytmusic_home_provider.dart
// Home-feed state management for the YouTube Music integration.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../models/ytmusic_models.dart';
import '../services/ytmusic_service.dart';
import 'library_provider.dart';

// ---------------------------------------------------------------------------
// Service provider
// ---------------------------------------------------------------------------

final ytMusicServiceProvider = Provider<YtMusicService>((ref) {
  ref.onDispose(() {});
  return YtMusicService.instance;
});

// ---------------------------------------------------------------------------
// HomeMood enum
// ---------------------------------------------------------------------------

enum HomeMood {
  relax('Relax'),
  energize('Energize'),
  workout('Workout'),
  focus('Focus'),
  commute('Commute'),
  party('Party'),
  sad('Sad'),
  romance('Romance');

  const HomeMood(this.label);
  final String label;

  List<String> get aliases {
    switch (this) {
      case HomeMood.relax:
        return ['relax', 'chill', 'calm', 'peaceful', 'mellow'];
      case HomeMood.energize:
        return ['energize', 'energy', 'energetic', 'upbeat', 'pump'];
      case HomeMood.workout:
        return ['workout', 'work out', 'fitness', 'gym', 'exercise', 'sport'];
      case HomeMood.focus:
        return ['focus', 'study', 'concentration', 'work', 'productivity'];
      case HomeMood.commute:
        return ['commute', 'driving', 'travel', 'road trip'];
      case HomeMood.party:
        return ['party', 'dance', 'festive', 'club'];
      case HomeMood.sad:
        return ['sad', 'heartbreak', 'blues', 'melancholy', 'emotional'];
      case HomeMood.romance:
        return ['romance', 'romantic', 'love', 'date night'];
    }
  }
}

// ---------------------------------------------------------------------------
// SectionState
// ---------------------------------------------------------------------------

enum SectionStatus { idle, loading, done, failed }

class SectionState {
  final SectionStatus status;
  final String? error;

  const SectionState({this.status = SectionStatus.idle, this.error});

  bool get isLoading => status == SectionStatus.loading;
  bool get isFailed => status == SectionStatus.failed;

  SectionState loading() => const SectionState(status: SectionStatus.loading);
  SectionState done() => const SectionState(status: SectionStatus.done);
  SectionState fail(String err) =>
      SectionState(status: SectionStatus.failed, error: err);
}

// ---------------------------------------------------------------------------
// MoodData — all sections for one mood (cached together)
// ---------------------------------------------------------------------------

class MoodData {
  final List<YtSong> songs;
  final List<YtAlbum> albums;
  final List<YtArtist> artists;
  final List<YtSong> trending;

  const MoodData({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.trending = const [],
  });

  bool get hasContent =>
      songs.isNotEmpty || albums.isNotEmpty || artists.isNotEmpty;
}

// ---------------------------------------------------------------------------
// HomeFeedState
// ---------------------------------------------------------------------------

class HomeFeedState {
  final bool isLoading;
  final String? error;
  final HomeMood? selectedMood;

  // ── Base sections (no mood) ────────────────────────────────────────────────
  final List<YtSong> quickPicks;
  final List<YtSong> mixedForYou;
  final List<YtSong> becauseYouListenedTo;
  final String? becauseArtistName;
  final List<YtAlbum> newReleases;
  final List<YtSong> trending;
  final List<YtArtist> artistsYouMightLike;
  final List<YtMoodChip> moodChips;

  // ── Per-section retry state ────────────────────────────────────────────────
  final SectionState quickPicksState;
  final SectionState exploreState;
  final SectionState moodState;
  final SectionState albumsForYouState;

  // ── Albums for you ─────────────────────────────────────────────────────────
  final List<YtAlbum> albumsForYou;

  // ── Mood cache ─────────────────────────────────────────────────────────────
  final Map<HomeMood, MoodData> moodCache;

  const HomeFeedState({
    this.isLoading = false,
    this.error,
    this.selectedMood,
    this.quickPicks = const [],
    this.mixedForYou = const [],
    this.becauseYouListenedTo = const [],
    this.becauseArtistName,
    this.newReleases = const [],
    this.trending = const [],
    this.artistsYouMightLike = const [],
    this.moodChips = const [],
    this.quickPicksState = const SectionState(),
    this.exploreState = const SectionState(),
    this.moodState = const SectionState(),
    this.albumsForYouState = const SectionState(),
    this.albumsForYou = const [],
    this.moodCache = const {},
  });

  // ── Active mood data (null when no mood selected) ─────────────────────────
  MoodData? get _activeMood =>
      selectedMood != null ? moodCache[selectedMood] : null;

  bool get isMoodActive => selectedMood != null && _activeMood != null;

  // ── Effective getters — switch to mood data when a mood is active ─────────

  List<YtSong> get effectiveQuickPicks {
    final m = _activeMood;
    return (m != null && m.songs.isNotEmpty) ? m.songs : quickPicks;
  }

  List<YtAlbum> get effectiveNewReleases {
    final m = _activeMood;
    return (m != null && m.albums.isNotEmpty) ? m.albums : newReleases;
  }

  List<YtArtist> get effectiveArtists {
    final m = _activeMood;
    return (m != null && m.artists.isNotEmpty) ? m.artists : artistsYouMightLike;
  }

  List<YtSong> get effectiveTrending {
    final m = _activeMood;
    return (m != null && m.trending.isNotEmpty) ? m.trending : trending;
  }

  /// When a mood is active, "Because you listened to" is replaced by the
  /// mood's second songs shelf (if it has one) or hidden.
  List<YtSong> get effectiveBecause {
    // When mood active, don't show the personalised "because" section —
    // the mood already fills quickPicks with relevant songs.
    return selectedMood == null ? becauseYouListenedTo : const [];
  }

  /// "Mixed for you" is personal, hide it when a mood is active.
  List<YtSong> get effectiveMixed {
    return selectedMood == null ? mixedForYou : const [];
  }

  // ── copyWith ───────────────────────────────────────────────────────────────

  HomeFeedState copyWith({
    bool? isLoading,
    Object? error = _keepValue,
    Object? selectedMood = _keepValue,
    List<YtSong>? quickPicks,
    List<YtSong>? mixedForYou,
    List<YtSong>? becauseYouListenedTo,
    Object? becauseArtistName = _keepValue,
    List<YtAlbum>? newReleases,
    List<YtSong>? trending,
    List<YtArtist>? artistsYouMightLike,
    List<YtMoodChip>? moodChips,
    SectionState? quickPicksState,
    SectionState? exploreState,
    SectionState? moodState,
    SectionState? albumsForYouState,
    List<YtAlbum>? albumsForYou,
    Map<HomeMood, MoodData>? moodCache,
  }) {
    return HomeFeedState(
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _keepValue) ? this.error : error as String?,
      selectedMood: identical(selectedMood, _keepValue)
          ? this.selectedMood
          : selectedMood as HomeMood?,
      quickPicks: quickPicks ?? this.quickPicks,
      mixedForYou: mixedForYou ?? this.mixedForYou,
      becauseYouListenedTo: becauseYouListenedTo ?? this.becauseYouListenedTo,
      becauseArtistName: identical(becauseArtistName, _keepValue)
          ? this.becauseArtistName
          : becauseArtistName as String?,
      newReleases: newReleases ?? this.newReleases,
      trending: trending ?? this.trending,
      artistsYouMightLike: artistsYouMightLike ?? this.artistsYouMightLike,
      moodChips: moodChips ?? this.moodChips,
      quickPicksState: quickPicksState ?? this.quickPicksState,
      exploreState: exploreState ?? this.exploreState,
      moodState: moodState ?? this.moodState,
      albumsForYouState: albumsForYouState ?? this.albumsForYouState,
      albumsForYou: albumsForYou ?? this.albumsForYou,
      moodCache: moodCache ?? this.moodCache,
    );
  }
}

const Object _keepValue = Object();

// ---------------------------------------------------------------------------
// HomeFeedNotifier
// ---------------------------------------------------------------------------

class HomeFeedNotifier extends StateNotifier<HomeFeedState> {
  final YtMusicService _service;
  final List<Song> _recentlyPlayed;
  // ignore: unused_field
  final List<Song> _likedSongs;

  /// Background revalidation channels. The service serves a stale feed
  /// instantly and refreshes behind it; these listeners patch the screen when
  /// the refresh lands and actually changed something.
  final Map<String, StreamSubscription<Object>> _revisionSubs = {};

  HomeFeedNotifier(
    this._service,
    this._recentlyPlayed,
    this._likedSongs,
  ) : super(const HomeFeedState(isLoading: true)) {
    _loadAll();
  }

  void _patch(HomeFeedState Function(HomeFeedState s) updater) {
    if (mounted) state = updater(state);
  }

  /// Subscribes to background updates for one feed.
  ///
  /// Returns the flag the caller must check before applying the value it gets
  /// back from its own await: a revision that arrives during that await
  /// already carries newer data, and applying the await's result afterwards
  /// would overwrite it with the stale payload we just replaced.
  ///
  /// ```dart
  /// final revisionPending = _watchRevision(key, apply);
  /// final value = await service.someGetter();
  /// if (revisionPending()) return;   // something already applied
  /// apply(value);
  /// ```
  bool Function() _watchRevision<T extends Object>(
    String key,
    void Function(T value) apply,
  ) {
    var applied = false;
    _revisionSubs[key]?.cancel();
    _revisionSubs[key] = _service.revisions<T>(key).listen((value) {
      applied = true;
      debugPrint('[HomeFeed] revision for $key — patching state');
      apply(value);
    });
    return () => applied;
  }

  @override
  void dispose() {
    for (final sub in _revisionSubs.values) {
      sub.cancel();
    }
    _revisionSubs.clear();
    super.dispose();
  }

  // ── Feed application ───────────────────────────────────────────────────────
  //
  // The initial read and the background revalidation both funnel through these
  // two methods, so a refreshed feed can never produce a differently-shaped
  // state than the first load did.

  /// Applies a home-feed payload.
  ///
  /// [albumsCollector] is only supplied by the first load: Albums For You
  /// needs the home shelves as a seed, and that computation runs exactly once
  /// per load, not on every revalidation.
  void _applyHomeFeed(
    List<YtSection> sections,
    List<YtMoodChip> chips,
    List<YtAlbum>? albumsCollector,
  ) {
    debugPrint('[HomeFeed] getHomeFeed → ${sections.length} sections, '
        '${chips.length} chips');
    for (final s in sections) {
      debugPrint('  section "${s.title}": '
          '${s.songs.length} songs, ${s.albums.length} albums, '
          '${s.artists.length} artists, ${s.playlists.length} playlists');
      if (albumsCollector == null) continue;
      // Collect all albums + playlists-as-albums for Albums For You
      albumsCollector.addAll(s.albums);
      for (final p in s.playlists) {
        albumsCollector.add(YtAlbum(
          browseId: p.browseId,
          title: p.title,
          artist: p.subtitle,
          coverUrl: p.coverUrl,
        ));
      }
    }

    YtSection? songShelf;
    for (final s in sections) {
      if (s.songs.isNotEmpty) {
        if (songShelf == null || s.songs.length > songShelf.songs.length) {
          songShelf = s;
        }
      }
    }

    _patch((s) => s.copyWith(
          quickPicks: songShelf?.songs ?? const [],
          moodChips: chips,
          quickPicksState: sections.isEmpty
              ? const SectionState().fail('No sections returned')
              : const SectionState().done(),
        ));
  }

  /// Applies an Explore payload, deriving New Releases and Trending from it.
  void _applyExplore(List<YtSection> sections) {
    debugPrint('[HomeFeed] getExplore → ${sections.length} sections');
    for (final s in sections) {
      debugPrint('  explore "${s.title}": '
          '${s.songs.length} songs, ${s.albums.length} albums, '
          '${s.playlists.length} playlists');
    }

    // New releases: prefer an albums shelf; fall back to playlists shelf
    // (explore sometimes encodes albums as playlist browse IDs).
    List<YtAlbum> releases = [];
    for (final s in sections) {
      if (s.albums.isNotEmpty) {
        releases = s.albums;
        break;
      }
    }
    // If still empty, try converting playlists to stub albums (title/cover)
    if (releases.isEmpty) {
      for (final s in sections) {
        if (s.playlists.isNotEmpty) {
          releases = s.playlists
              .map((p) => YtAlbum(
                    browseId: p.browseId,
                    title: p.title,
                    artist: p.subtitle,
                    coverUrl: p.coverUrl,
                  ))
              .toList();
          debugPrint('[HomeFeed] new releases: used playlists shelf '
              '"${s.title}" (${releases.length} items)');
          break;
        }
      }
    }

    // Trending: first songs shelf; prefer one whose title contains
    // "trending", "chart", or "top" — otherwise just take the biggest.
    List<YtSong> trendingSongs = [];
    YtSection? best;
    for (final s in sections) {
      if (s.songs.isEmpty) continue;
      final lower = s.title.toLowerCase();
      final isPrimary = lower.contains('trend') ||
          lower.contains('chart') ||
          lower.contains('top');
      if (isPrimary) {
        trendingSongs = s.songs;
        break;
      }
      if (best == null || s.songs.length > best.songs.length) {
        best = s;
      }
    }
    if (trendingSongs.isEmpty && best != null) {
      trendingSongs = best.songs;
    }

    debugPrint('[HomeFeed] new releases: ${releases.length}, '
        'trending: ${trendingSongs.length}');

    _patch((s) => s.copyWith(
          newReleases: releases,
          trending: trendingSongs,
          exploreState: sections.isEmpty
              ? const SectionState().fail('No explore sections')
              : const SectionState().done(),
        ));
  }

  // ── Primary load ───────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    _patch((s) => s.copyWith(
          isLoading: true,
          error: null,
          quickPicksState: const SectionState().loading(),
          exploreState: const SectionState().loading(),
          albumsForYouState: const SectionState().loading(),
        ));

    int inFlight = _recentlyPlayed.isNotEmpty ? 3 : 2;

    void taskDone() {
      inFlight--;
      if (inFlight <= 0) {
        _patch((s) => s.copyWith(isLoading: false));
      }
    }

    // Shared data collected by home feed task, used later by albumsTask
    final homeAlbumsCollected = <YtAlbum>[];

    // ── 1. Home feed ──────────────────────────────────────────────────────────
    // Subscribe first so a background revalidation landing during the await is
    // not lost to the stale payload we are about to discard.
    final homeFeedRevision = _watchRevision<(List<YtSection>, List<YtMoodChip>)>(
      YtMusicService.kHomeFeedKey,
      (value) => _applyHomeFeed(value.$1, value.$2, null),
    );

    _service.getHomeFeed().then((result) {
      if (homeFeedRevision()) return;
      _applyHomeFeed(result.$1, result.$2, homeAlbumsCollected);
    }).catchError((e) {
      debugPrint('[HomeFeed] getHomeFeed failed: $e');
      _patch((s) => s.copyWith(
            quickPicksState:
                const SectionState().fail('Could not load feed: $e'),
          ));
    }).whenComplete(taskDone);

    // ── 2. Explore ────────────────────────────────────────────────────────────
    final exploreRevision =
        _watchRevision<List<YtSection>>(YtMusicService.kExploreKey, _applyExplore);

    _service.getExplore().then((sections) {
      if (exploreRevision()) return;
      _applyExplore(sections);
    }).catchError((e) {
      debugPrint('[HomeFeed] getExplore failed: $e');
      _patch((s) => s.copyWith(
            exploreState:
                const SectionState().fail('Could not load explore: $e'),
          ));
    }).whenComplete(taskDone);

    // ── 3. Artist personalisation + Albums For You ────────────────────────────
    if (_recentlyPlayed.isEmpty) {
      // No history → no artist tasks, but still load Albums For You
      _service
          .getAlbumsForYou(homeAlbums: homeAlbumsCollected)
          .then((albums) {
            debugPrint('[HomeFeed] getAlbumsForYou (no history) → ${albums.length}');
            _patch((s) => s.copyWith(
                  albumsForYou: albums,
                  albumsForYouState: const SectionState().done(),
                ));
          })
          .catchError((e) {
            debugPrint('[HomeFeed] getAlbumsForYou (no history) error: $e');
            _patch((s) => s.copyWith(
                  albumsForYouState:
                      const SectionState().fail('Could not load: $e'),
                ));
          })
          .whenComplete(taskDone);
      return;
    }

    final topSong = _recentlyPlayed.first;

    final artistFrequency = <String, int>{};
    for (final song in _recentlyPlayed) {
      artistFrequency[song.channelName] =
          (artistFrequency[song.channelName] ?? 0) + 1;
    }
    final topArtistName = artistFrequency.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    Future<void> artistTasks() async {
      try {
        final upNext = await _service.getUpNext(topSong.id);
        debugPrint('[HomeFeed] getUpNext → ${upNext.length} songs');
        _patch((s) => s.copyWith(mixedForYou: upNext));
      } catch (e) {
        debugPrint('[HomeFeed] getUpNext failed: $e');
      }

      try {
        final songResults = await _service.searchSongs(topArtistName);
        debugPrint('[HomeFeed] searchSongs("$topArtistName") → '
            '${songResults.length} songs');

        final artistSongs = songResults
            .where((s) =>
                s.artist.toLowerCase().contains(topArtistName.toLowerCase()))
            .take(20)
            .toList();

        _patch((s) => s.copyWith(
              becauseYouListenedTo: artistSongs.isNotEmpty
                  ? artistSongs
                  : songResults.take(20).toList(),
              becauseArtistName: topArtistName,
            ));

        final existingArtist = state.artistsYouMightLike
            .cast<YtArtist?>()
            .firstWhere(
              (a) =>
                  a!.name.toLowerCase().contains(topArtistName.toLowerCase()),
              orElse: () => null,
            );

        final artistBrowseId = existingArtist?.browseId;
        if (artistBrowseId != null) {
          try {
            final topArtistSongs =
                await _service.getArtistTopSongs(artistBrowseId);
            if (topArtistSongs.isNotEmpty) {
              _patch((s) => s.copyWith(becauseYouListenedTo: topArtistSongs));
            }
            final related = await _service.getRelatedArtists(artistBrowseId);
            debugPrint('[HomeFeed] getRelatedArtists → ${related.length}');
            _patch((s) => s.copyWith(artistsYouMightLike: related));
          } catch (e) {
            debugPrint('[HomeFeed] artist browse failed: $e');
          }
        }
      } catch (e) {
        debugPrint('[HomeFeed] artist tasks failed: $e');
      }
    }

    artistTasks().whenComplete(taskDone);

    // ── 4. Albums For You — runs after artist tasks so IDs are populated ──────
    // We chain this inside artistTasks completion so state.artistsYouMightLike
    // is already set when we read it.
    Future<void> albumsTask() async {
      // Wait for artistTasks to finish by chaining on the same future.
      // artistTasks already called taskDone() for its slot; albums gets its own.
      try {
        // Collect artist browseIds from state — populated by artistTasks above
        final artistIds = state.artistsYouMightLike
            .take(5)
            .map((a) => a.browseId)
            .where((id) => id.isNotEmpty)
            .toList();

        // Also pass any explore albums we already have as a direct fallback
        // so the service doesn't need a second network call
        final albums = await _service.getAlbumsForYou(
          topArtistBrowseIds: artistIds,
          homeAlbums: homeAlbumsCollected,
        );
        debugPrint('[HomeFeed] getAlbumsForYou → ${albums.length} albums');
        _patch((s) => s.copyWith(
              albumsForYou: albums,
              // Empty = section stays hidden (no error row), not a failure
              albumsForYouState: const SectionState().done(),
            ));
      } catch (e) {
        debugPrint('[HomeFeed] getAlbumsForYou failed: $e');
        _patch((s) => s.copyWith(
              albumsForYouState:
                  const SectionState().fail('Could not load albums: $e'),
            ));
      }
    }

    // Chain albums after artist tasks so artist IDs are ready
    artistTasks().then((_) => albumsTask()).whenComplete(taskDone);
  }

  // ── Mood selection ─────────────────────────────────────────────────────────

  Future<void> selectMood(HomeMood? mood) async {
    // Deselect
    if (mood == state.selectedMood) {
      _patch((s) => s.copyWith(selectedMood: null));
      return;
    }

    _patch((s) => s.copyWith(
          selectedMood: mood,
          moodState: const SectionState().loading(),
        ));

    if (mood == null) return;

    // Already cached
    final cached = state.moodCache[mood];
    if (cached != null && cached.hasContent) {
      _patch((s) => s.copyWith(moodState: const SectionState().done()));
      return;
    }

    final chip = _findMoodChip(mood, state.moodChips);
    debugPrint('[HomeFeed] selectMood(${mood.label}): '
        'chip=${chip?.label ?? "none"}');

    List<YtSection> sections = [];
    if (chip != null) {
      try {
        sections = await _service.getHomeFeedForMood(chip.params);
        debugPrint('[HomeFeed] getHomeFeedForMood(${mood.label}) → '
            '${sections.length} sections');
        for (final s in sections) {
          debugPrint('  mood section "${s.title}": '
              '${s.songs.length} songs, ${s.albums.length} albums, '
              '${s.artists.length} artists');
        }
      } catch (e) {
        debugPrint('[HomeFeed] getHomeFeedForMood failed: $e');
      }
    }

    // Distribute sections across mood slots:
    // songs shelves → quickPicks (largest) + trending (second)
    // albums shelf  → newReleases
    // artists shelf → artistsYouMightLike
    final songShelves =
        sections.where((s) => s.songs.isNotEmpty).toList()
          ..sort((a, b) => b.songs.length.compareTo(a.songs.length));
    final albumShelf = sections.firstWhere(
      (s) => s.albums.isNotEmpty,
      orElse: () =>
          const YtSection(title: '', songs: [], albums: [], artists: [], playlists: []),
    );
    final artistShelf = sections.firstWhere(
      (s) => s.artists.isNotEmpty,
      orElse: () =>
          const YtSection(title: '', songs: [], albums: [], artists: [], playlists: []),
    );

    List<YtSong> moodSongs =
        songShelves.isNotEmpty ? songShelves[0].songs : [];
    List<YtSong> moodTrending =
        songShelves.length > 1 ? songShelves[1].songs : [];
    List<YtAlbum> moodAlbums = albumShelf.albums;
    List<YtArtist> moodArtists = artistShelf.artists;

    // Fallback: search if API returned nothing useful
    if (moodSongs.isEmpty) {
      try {
        debugPrint('[HomeFeed] mood fallback search: "${mood.label} music"');
        final fallback = await _service.searchSongs('${mood.label} music');
        moodSongs = fallback;
        debugPrint('[HomeFeed] fallback → ${moodSongs.length} songs');
      } catch (e) {
        debugPrint('[HomeFeed] mood fallback search failed: $e');
      }
    }

    // Also convert playlists to stub albums if no real albums
    if (moodAlbums.isEmpty) {
      final playlistShelf = sections.firstWhere(
        (s) => s.playlists.isNotEmpty,
        orElse: () => const YtSection(
            title: '', songs: [], albums: [], artists: [], playlists: []),
      );
      if (playlistShelf.playlists.isNotEmpty) {
        moodAlbums = playlistShelf.playlists
            .map((p) => YtAlbum(
                  browseId: p.browseId,
                  title: p.title,
                  artist: p.subtitle,
                  coverUrl: p.coverUrl,
                ))
            .toList();
      }
    }

    debugPrint('[HomeFeed] mood(${mood.label}): '
        '${moodSongs.length} songs, ${moodTrending.length} trending, '
        '${moodAlbums.length} albums, ${moodArtists.length} artists');

    final newCache = Map<HomeMood, MoodData>.from(state.moodCache)
      ..[mood] = MoodData(
        songs: moodSongs,
        albums: moodAlbums,
        artists: moodArtists,
        trending: moodTrending,
      );

    _patch((s) => s.copyWith(
          moodCache: newCache,
          moodState: const SectionState().done(),
        ));
  }

  YtMoodChip? _findMoodChip(HomeMood mood, List<YtMoodChip> chips) {
    if (chips.isEmpty) return null;
    final aliases = mood.aliases;

    for (final alias in aliases) {
      for (final chip in chips) {
        if (chip.label.toLowerCase() == alias) return chip;
      }
    }
    for (final alias in aliases) {
      for (final chip in chips) {
        if (chip.label.toLowerCase().contains(alias)) return chip;
      }
    }
    for (final chip in chips) {
      for (final alias in aliases) {
        if (alias.contains(chip.label.toLowerCase())) return chip;
      }
    }
    return null;
  }

  // ── Retry individual sections ──────────────────────────────────────────────

  Future<void> retryQuickPicks() async {
    _patch((s) => s.copyWith(quickPicksState: const SectionState().loading()));
    try {
      // Drops the disk tier too, so a retry really re-fetches instead of being
      // handed the rows it is meant to replace. That also tears down the
      // revision channels, so re-subscribe below.
      _service.clearCache();
      final revision = _watchRevision<(List<YtSection>, List<YtMoodChip>)>(
        YtMusicService.kHomeFeedKey,
        (value) => _applyHomeFeed(value.$1, value.$2, null),
      );
      final result = await _service.getHomeFeed();
      if (revision()) return;
      _applyHomeFeed(result.$1, result.$2, null);
    } catch (e) {
      _patch((s) => s.copyWith(
            quickPicksState: const SectionState().fail('Could not load: $e'),
          ));
    }
  }

  Future<void> retryExplore() async {
    _patch((s) => s.copyWith(exploreState: const SectionState().loading()));
    try {
      _service.clearCache();
      final revision = _watchRevision<List<YtSection>>(
        YtMusicService.kExploreKey,
        _applyExplore,
      );
      final sections = await _service.getExplore();
      if (revision()) return;
      _applyExplore(sections);
    } catch (e) {
      _patch((s) => s.copyWith(
            exploreState: const SectionState().fail('Could not load: $e'),
          ));
    }
  }

  Future<void> retryAlbumsForYou() async {
    _patch((s) =>
        s.copyWith(albumsForYouState: const SectionState().loading()));
    try {
      final artistIds = state.artistsYouMightLike
          .take(5)
          .map((a) => a.browseId)
          .where((id) => id.isNotEmpty)
          .toList();
      final albums = await _service.getAlbumsForYou(
        topArtistBrowseIds: artistIds,
      );
      _patch((s) => s.copyWith(
            albumsForYou: albums,
            albumsForYouState: const SectionState().done(),
          ));
    } catch (e) {
      _patch((s) => s.copyWith(
            albumsForYouState:
                const SectionState().fail('Could not load: $e'),
          ));
    }
  }

  // ── Refresh ────────────────────────────────────────────────────────────────

  Future<void> refresh() async {
    _service.clearCache();
    _patch((_) => const HomeFeedState(isLoading: true));
    await _loadAll();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final homeFeedProvider =
    StateNotifierProvider<HomeFeedNotifier, HomeFeedState>((ref) {
  final library = ref.read(libraryProvider);
  return HomeFeedNotifier(
    ref.watch(ytMusicServiceProvider),
    library.recentlyPlayed,
    library.likedSongs,
  );
});
