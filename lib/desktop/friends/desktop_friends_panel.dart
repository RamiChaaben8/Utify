// ============================================================
// desktop/friends/desktop_friends_panel.dart
//
// Desktop-only friends surface, rendered into the shell's right-hand
// column alongside Now Playing and the Queue.
//
// This used to be a centre view (_currentView == 3). As a page it
// took the whole middle of the window for a list of people, and
// opening it cost you the Now Playing panel. Spotify keeps friend
// activity in the side column instead, so the friends icon in the
// title bar toggles this panel and the centre view is left alone.
//
// Deliberately narrower furniture than the centre view it replaces:
// a fixed header (title + close, then the three tabs) with only the
// body scrolling, and no page title, divider gutter or 38px padding.
//
// Reached via PanelMode.friends — see providers/panel_provider.dart.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/song.dart';
import '../../providers/friends_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/presence_provider.dart';
import '../../services/firestore_service.dart';
import '../shell/desktop_navigation.dart';
import '../theme/desktop_theme.dart';
import '../widgets/song_leading_indicator.dart';

enum _FriendsTab { friends, requests, add }

class DesktopFriendsPanel extends ConsumerStatefulWidget {
  /// Width to render at. Shares the now-playing panel's width and resize
  /// handle, so switching panels does not jump or reset the user's drag.
  final double? width;

  /// Closes the panel — the header X and anything else that wants out.
  final VoidCallback onClose;

  const DesktopFriendsPanel({
    super.key,
    required this.onClose,
    this.width,
  });

  @override
  ConsumerState<DesktopFriendsPanel> createState() =>
      _DesktopFriendsPanelState();
}

class _DesktopFriendsPanelState extends ConsumerState<DesktopFriendsPanel> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  _FriendsTab _tab = _FriendsTab.friends;
  List<PublicProfile> _results = const [];
  bool _searching = false;
  String? _sendingRequestUid;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Windows has no Firestore snapshot listener on the friendships stream
    // (see FriendsNotifier.initForUser), so presence and requests only update
    // if something polls. Match the cadence the mobile view used here.
    //
    // The panel is only built while it is open, so this timer does not run in
    // the background when friends are hidden.
    if (Platform.isWindows) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) ref.read(friendsProvider.notifier).refresh();
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String? get _currentUid => ref.read(friendsProvider.notifier).uid;

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    final results = await ref.read(friendsProvider.notifier).search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _sendRequest(PublicProfile profile) async {
    setState(() => _sendingRequestUid = profile.uid);
    final success =
        await ref.read(friendsProvider.notifier).sendRequest(profile.uid);
    if (!mounted) return;
    setState(() => _sendingRequestUid = null);
    if (success) {
      setState(() => _tab = _FriendsTab.requests);
      _showSnack('Friend request sent to @${profile.username}.');
    } else {
      final error = ref.read(friendsProvider).error;
      if (error != null) {
        _showSnack(error);
        ref.read(friendsProvider.notifier).clearError();
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ));
  }

  /// Opens a friend in the centre view. The panel is far too narrow for the
  /// playlist grid, so this asks the shell rather than swapping its own body —
  /// see desktop_navigation.dart.
  void _openProfile(PublicProfile profile) {
    ref.read(desktopFriendProfileRequestProvider.notifier).state = profile;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final layout = theme.layout;
    final state = ref.watch(friendsProvider);

    // Surface provider errors here rather than in a nested messenger — the
    // shell owns the only one in the tree.
    ref.listen(friendsProvider.select((s) => s.error), (prev, next) {
      if (next == null || next == prev) return;
      _showSnack(next);
      ref.read(friendsProvider.notifier).clearError();
    });

    final pendingCount = state.incomingRequests.length +
        state.outgoingRequests
            .where((o) => !state.incomingRequests.any((i) => i.id == o.id))
            .length;

    return Container(
      width: widget.width,
      // Identical chrome to QueuePanel / DesktopNowPlayingPanel so all three
      // swap cleanly: same surface, same left hairline, same corner treatment.
      decoration: BoxDecoration(
        color: theme.panelSurfaceColor,
        border: Border(left: BorderSide(color: theme.dividerColor)),
        borderRadius: layout.squareNowPlayingArt
            ? BorderRadius.circular(layout.panelRadius)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Fixed header ────────────────────────────────────────────
          _Header(onClose: widget.onClose),
          _CompactTabs(
            selected: _tab,
            pendingCount: pendingCount,
            onChanged: (tab) {
              setState(() => _tab = tab);
              if (tab == _FriendsTab.add) {
                _searchFocus.requestFocus();
              }
            },
          ),
          Divider(
              color: theme.dividerColor, height: 1, thickness: 0.5),

          // ── Scrolling body ──────────────────────────────────────────
          Expanded(
            child: switch (_tab) {
              _FriendsTab.friends => _friendsBody(state),
              _FriendsTab.requests => _requestsBody(state),
              _FriendsTab.add => _addBody(),
            },
          ),
        ],
      ),
    );
  }

  // ── Friends ────────────────────────────────────────────────────────────────

  Widget _friendsBody(FriendsState state) {
    if (state.loading && state.friendships.isEmpty) {
      return const _Loading();
    }
    final friends = state.accepted;
    if (friends.isEmpty) {
      return const _EmptyBox(
        icon: Icons.people_outline,
        title: 'No friends yet',
        subtitle: 'Add someone by username from the Add friend tab.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: friends.length,
      // ~16px between rows, per the panel spec.
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final friendship = friends[i];
        return _FriendRow(
          friendship: friendship,
          onOpenProfile: () => _openProfile(friendship.profile!),
          onUnfriend: () =>
              ref.read(friendsProvider.notifier).unfriend(friendship),
          onBlock: () {
            final otherUid = friendship.otherUid;
            if (otherUid == null) return;
            ref.read(friendsProvider.notifier).block(otherUid);
          },
        );
      },
    );
  }

  // ── Requests ───────────────────────────────────────────────────────────────

  Widget _requestsBody(FriendsState state) {
    final requests = [
      ...state.incomingRequests,
      ...state.outgoingRequests.where((outgoing) =>
          !state.incomingRequests.any((item) => item.id == outgoing.id)),
    ];
    if (requests.isEmpty) {
      return const _EmptyBox(
        icon: Icons.mark_email_unread_outlined,
        title: 'No pending requests',
        subtitle: 'Requests you send or receive will show up here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: requests.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final request = requests[i];
        final incoming = request.requestedBy != _currentUid;
        return _RequestRow(
          profile: request.profile,
          incoming: incoming,
          onAccept: incoming
              ? () => ref.read(friendsProvider.notifier).accept(request)
              : null,
          onDecline: () => ref.read(friendsProvider.notifier).decline(request),
        );
      },
    );
  }

  // ── Add friend ─────────────────────────────────────────────────────────────

  Widget _addBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // No fixed width: this lives in the resizable side column now, so it
        // has to track the panel rather than a centre-view pixel value.
        TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          style: TextStyle(color: context.appTheme.text),
          decoration: InputDecoration(
            hintText: 'Search username',
            hintStyle: TextStyle(color: context.appTheme.subtext),
            prefixIcon:
                Icon(Icons.search, color: context.appTheme.subtext, size: 20),
            suffixIcon: IconButton(
              tooltip: 'Search',
              onPressed: _searching ? null : _search,
              icon: _searching
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.appTheme.usesModernDesign
                            ? context.appTheme.subtext
                            : context.appTheme.button,
                      ),
                    )
                  : Icon(Icons.arrow_forward,
                      color: context.appTheme.iconDefault, size: 20),
            ),
            filled: true,
            fillColor: context.appTheme.card,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                  context.appTheme.layout.searchRadius),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_results.isEmpty)
          const _EmptyBox(
            icon: Icons.person_search,
            title: 'Find someone',
            subtitle: 'Search by username to send a friend request.',
          )
        else
          ..._results.map((profile) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: _SearchResultRow(
                  profile: profile,
                  busy: _sendingRequestUid == profile.uid,
                  onAdd: () => _sendRequest(profile),
                ),
              )),
      ],
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final VoidCallback onClose;

  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          // `nowPlayingAccent` is the accent token: the green in Green/Red, the
          // lime in Verdant Night.
          Expanded(
            child: Text(
              'Friend activity',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.nowPlayingAccent,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Tooltip(
            message: 'Close friend activity',
            child: IconButton(
              icon: Icon(Icons.close, color: theme.subtext, size: 18),
              onPressed: onClose,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Compact tab row ─────────────────────────────────────────────────────────

/// The same three tabs the centre view had, shrunk to fit a side column:
/// smaller type and tighter padding inside the same accent-fill segmented
/// control. The selected segment keeps [onButtonFill] text — never `text`,
/// which is lime in Verdant Night.
class _CompactTabs extends StatelessWidget {
  final _FriendsTab selected;
  final int pendingCount;
  final ValueChanged<_FriendsTab> onChanged;

  const _CompactTabs({
    required this.selected,
    required this.pendingCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final labels = {
      _FriendsTab.friends: 'Friends',
      _FriendsTab.requests:
          pendingCount == 0 ? 'Requests' : 'Requests ($pendingCount)',
      _FriendsTab.add: 'Add',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(theme.layout.searchRadius),
        ),
        // Segments are Flexible so a long "Requests (12)" ellipsises instead of
        // overflowing the track in a 300px panel.
        child: Row(
          children: _FriendsTab.values.map((tab) {
            final active = tab == selected;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Material(
                  color: active ? theme.button : Colors.transparent,
                  borderRadius:
                      BorderRadius.circular(theme.layout.searchRadius),
                  child: InkWell(
                    borderRadius:
                        BorderRadius.circular(theme.layout.searchRadius),
                    onTap: () => onChanged(tab),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Text(
                        labels[tab]!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: active ? theme.onButtonFill : theme.subtext,
                          fontSize: 12,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ─── Friend row ──────────────────────────────────────────────────────────────

/// Compact three-line row: 40px avatar with a presence dot, name, what they
/// are playing, then a context line. The ⋯ menu is always at the far right and
/// only becomes visible (and clickable) on hover.
///
/// The row itself is not tappable — opening a friend is an explicit choice from
/// the ⋯ menu, since the profile page needs the full centre view.
class _FriendRow extends ConsumerStatefulWidget {
  final Friendship friendship;
  final VoidCallback onOpenProfile;
  final VoidCallback onUnfriend;
  final VoidCallback onBlock;

  const _FriendRow({
    required this.friendship,
    required this.onOpenProfile,
    required this.onUnfriend,
    required this.onBlock,
  });

  @override
  ConsumerState<_FriendRow> createState() => _FriendRowState();
}

class _FriendRowState extends ConsumerState<_FriendRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final friendship = widget.friendship;
    final profile = friendship.profile;
    final otherUid = friendship.otherUid;

    if (profile == null || otherUid == null) {
      return _row(
        child: Row(
          children: [
            const _Avatar(profile: null, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '@${profile?.username ?? 'unknown'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.text, fontSize: 14),
              ),
            ),
          ],
        ),
      );
    }

    final presence = ref.watch(friendPresenceProvider(otherUid)).valueOrNull;
    final online = presence?.isOnline == true;
    // Single source of truth. Gating on `isOnline` here is what stops a friend
    // who has gone offline from keeping the equalizer, since Firestore keeps
    // their last `activity` map until something overwrites it.
    final listening = presence?.isListening == true;

    final activity = presence?.activity;
    final track = listening ? activity : null;

    return _row(
      // Offline rows read as inactive rather than being hidden outright.
      opacity: online ? 1.0 : 0.55,
      onSecondaryTap: _showMenu,
      child: Row(
        children: [
          _Avatar(profile: profile, size: 40, online: online),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  profile.displayName.isNotEmpty
                      ? profile.displayName
                      : '@${profile.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.nowPlayingAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track == null
                      ? (online ? 'Online' : 'Offline')
                      : '${track['title'] ?? 'Listening'} • ${track['artist'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.subtext, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  _contextLine(presence, online: online, listening: listening),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.subtext.withValues(alpha: 0.75),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (listening) ...[
            EqualizerBars(color: theme.nowPlayingAccent, size: 14),
            const SizedBox(width: 8),
          ],
          _menuButton(),
        ],
      ),
    );
  }

  /// Third line. Presence publishes no album or playlist name, so the context
  /// we can honestly show is which device they are listening on. Offline
  /// friends get the last-seen stamp instead.
  String _contextLine(
    PresenceInfo? presence, {
    required bool online,
    required bool listening,
  }) {
    if (!online) {
      final seen = _lastSeen(presence?.lastActiveAt);
      return seen.isEmpty ? 'Offline' : 'Offline$seen';
    }
    if (!listening) return 'Not playing';
    final device = presence?.deviceName ?? '';
    return device.isEmpty ? '' : 'on $device';
  }

  /// Fixed-width slot so revealing it on hover cannot reflow the row.
  Widget _menuButton() {
    final theme = context.appTheme;
    return SizedBox(
      width: 28,
      child: AnimatedOpacity(
        opacity: _hovered ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 150),
        // AnimatedOpacity still hit-tests at 0, which would leave an invisible
        // button sitting over the row.
        child: IgnorePointer(
          ignoring: !_hovered,
          child: Tooltip(
            message: 'More',
            child: IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () {
                final box = context.findRenderObject() as RenderBox?;
                _showMenu(
                  box == null
                      ? Offset.zero
                      : box.localToGlobal(box.size.bottomRight(Offset.zero)),
                );
              },
              icon: Icon(Icons.more_horiz, color: theme.subtext),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row({
    required Widget child,
    double opacity = 1.0,
    void Function(Offset position)? onSecondaryTap,
  }) {
    final theme = context.appTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // No pointer cursor: the row is not tappable, only its ⋯ menu is.
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onSecondaryTapDown: onSecondaryTap == null
            ? null
            : (d) => onSecondaryTap(d.globalPosition),
        child: Opacity(
          opacity: opacity,
          child: Material(
            color: _hovered ? theme.highlight : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {},
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMenu(Offset position) {
    final theme = context.appTheme;
    final profile = widget.friendship.profile!;
    final presence =
        ref.read(friendPresenceProvider(widget.friendship.otherUid!))
            .valueOrNull;
    final listening = presence?.isListening == true;
    final track = listening ? _trackFromActivity(presence!.activity!) : null;

    showMenu<_RowAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: theme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.dividerColor),
      ),
      items: [
        _menuItem(
          context,
          Icons.headphones,
          "Listen to what ${_firstName(profile)} is listening to",
          _RowAction.listenAlong,
          enabled: track != null,
          disabledTooltip: track == null
              // Distinguish "paused / stopped" from "presence data has no
              // playable id", since only the former is a normal state.
              ? (presence?.activity == null
                  ? 'Not listening to anything right now'
                  : 'That track cannot be played from here')
              : null,
        ),
        _menuItem(context, Icons.open_in_new, 'Open profile', _RowAction.open),
        _menuItem(context, Icons.person_remove_outlined, 'Unfriend',
            _RowAction.unfriend),
        _menuItem(context, Icons.block, 'Block', _RowAction.block),
      ],
    ).then((value) {
      if (!mounted || value == null) return;
      switch (value) {
        case _RowAction.listenAlong:
          if (track != null) _listenAlong(track);
        case _RowAction.open:
          widget.onOpenProfile();
        case _RowAction.unfriend:
          widget.onUnfriend();
        case _RowAction.block:
          widget.onBlock();
      }
    });
  }

  /// Builds a playable [Song] from a presence activity map.
  ///
  /// `trackId` is the YouTube video id, which is exactly `Song.id`, so the
  /// friend can hand us an id we can resolve and play without any extra lookup.
  static Song? _trackFromActivity(Map<String, dynamic> activity) {
    final id = activity['trackId'];
    if (id is! String || id.isEmpty) return null;
    return Song(
      id: id,
      title: (activity['title'] as String?) ?? 'Unknown track',
      channelName: (activity['artist'] as String?) ?? '',
      thumbnailUrl: (activity['coverUrl'] as String?) ?? '',
      duration: Duration(
        milliseconds: (activity['durationMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  /// Plays only the friend's current track, leaving our queue untouched.
  ///
  /// Passing `queue: [song]` hands the player a one-item queue, so this replaces
  /// what we were listening to rather than splicing into our own queue. Our real
  /// queue is restored by nothing here on purpose — the ask was explicitly a
  /// single track, not a queue merge, and rebuilding our queue from stale state
  /// after the fact would race with whatever the user is doing.
  Future<void> _listenAlong(Song track) async {
    ref.read(playerProvider.notifier).playSong(track, queue: [track]);

    // playSong reports failures through player state rather than by throwing, so
    // watch for the error this play may raise instead of crashing the row.
    final error = await _awaitPlayResult(track.id);
    if (!mounted) return;
    if (error != null) {
      _showSnack("Couldn't play that track: $error");
    } else {
      _showSnack('Playing ${track.title} — ${track.channelName}'.trim());
    }
  }

  /// Resolves with the player's error for this attempt, or null once the
  /// requested track loads cleanly.
  ///
  /// `playSong` reports failures by writing `error` into player state rather
  /// than by throwing, so this watches for that transition. `listenManual` is
  /// used because `WidgetRef.listen` returns void here and cannot be closed
  /// when the row goes away.
  Future<String?> _awaitPlayResult(String trackId) {
    final completer = Completer<String?>();
    var sawRequest = false;

    final sub = ref.listenManual<PlayerState>(playerProvider, (prev, next) {
      if (completer.isCompleted) return;
      if (next.currentSong?.id == trackId) sawRequest = true;

      // An error raised while our track is the one loaded is ours to report.
      if (sawRequest && next.error != null && next.isLoading == false) {
        completer.complete(next.error);
        return;
      }
      // Loaded, not loading, no error: the play succeeded.
      if (sawRequest &&
          next.currentSong?.id == trackId &&
          next.isLoading == false) {
        completer.complete(null);
      }
    }, fireImmediately: true);

    // Safety net so a provider that never settles cannot wedge the caller, and
    // so the subscription does not outlive a row that scrolled away.
    Future<void>.delayed(const Duration(seconds: 10), () {
      sub.close();
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ));
  }

  PopupMenuItem<_RowAction> _menuItem(
    BuildContext context,
    IconData icon,
    String label,
    _RowAction value, {
    bool enabled = true,
    String? disabledTooltip,
  }) {
    final theme = context.appTheme;
    final color = enabled ? theme.text : theme.subtext;
    final row = Row(
      children: [
        Icon(icon, size: 16, color: theme.subtext),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
        ),
      ],
    );

    return PopupMenuItem<_RowAction>(
      value: value,
      enabled: enabled,
      // A disabled PopupMenuItem does not receive hover, so the reason has to
      // ride along in the item body rather than in a Tooltip.
      child: disabledTooltip == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                row,
                const SizedBox(height: 2),
                Text(
                  disabledTooltip,
                  style: TextStyle(
                    color: theme.subtext.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
    );
  }
}

/// First name for menu copy, falling back to the handle when there is no
/// display name. Kept short so the menu entry stays on one line.
String _firstName(PublicProfile profile) {
  final name = profile.displayName.trim();
  if (name.isEmpty) return '@${profile.username}';
  return name.split(RegExp(r'\s+')).first;
}

enum _RowAction { listenAlong, open, unfriend, block }

/// Returns the " • last seen …" fragment, or an empty string when there is no
/// timestamp to report.
String _lastSeen(DateTime? lastActiveAt) {
  if (lastActiveAt == null) return '';
  final elapsed = DateTime.now().difference(lastActiveAt);
  if (elapsed.inMinutes < 1) return ' • last seen just now';
  if (elapsed.inHours < 1) return ' • last seen ${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return ' • last seen ${elapsed.inHours}h ago';
  return ' • last seen ${elapsed.inDays}d ago';
}

// ─── Request row ─────────────────────────────────────────────────────────────

class _RequestRow extends StatelessWidget {
  final PublicProfile? profile;
  final bool incoming;
  final VoidCallback? onAccept;
  final VoidCallback onDecline;

  const _RequestRow({
    required this.profile,
    required this.incoming,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return _RowShell(
      leading: _Avatar(profile: profile, size: 40),
      title: '@${profile?.username ?? 'unknown'}',
      subtitle: profile?.displayName ?? '',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (incoming)
            _RoundIconButton(
              tooltip: 'Accept',
              icon: Icons.check,
              color: theme.nowPlayingAccent,
              onPressed: onAccept,
            ),
          _RoundIconButton(
            tooltip: incoming ? 'Decline' : 'Cancel request',
            icon: incoming ? Icons.close : Icons.undo,
            color: theme.iconDefault,
            onPressed: onDecline,
          ),
        ],
      ),
    );
  }
}

/// Static two-line row for requests and search results — same shape as the
/// friend row minus presence, the equalizer and the ⋯ menu.
class _RowShell extends StatefulWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _RowShell({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  State<_RowShell> createState() => _RowShellState();
}

class _RowShellState extends State<_RowShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.basic,
      child: Material(
        color: _hovered ? theme.highlight : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                widget.leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.subtext, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 8),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  const _RoundIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  State<_RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<_RoundIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: widget.onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovered && widget.onPressed != null
                  ? context.appTheme.highlightElevated
                  : Colors.transparent,
            ),
            child: Icon(widget.icon, size: 17, color: widget.color),
          ),
        ),
      ),
    );
  }
}

// ─── Search result row ───────────────────────────────────────────────────────

class _SearchResultRow extends StatelessWidget {
  final PublicProfile profile;
  final bool busy;
  final VoidCallback onAdd;

  const _SearchResultRow({
    required this.profile,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final name = profile.displayName.isEmpty
        ? '@${profile.username}'
        : profile.displayName;

    return _RowShell(
      leading: _Avatar(profile: profile, size: 40),
      title: name,
      subtitle: '@${profile.username}',
      trailing: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.button,
          foregroundColor: theme.onButtonFill,
          disabledBackgroundColor: theme.highlightElevated,
          disabledForegroundColor: theme.subtext,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          shape: const StadiumBorder(),
        ),
        onPressed: busy ? null : onAdd,
        child: busy
            // Sits on the accent fill — the default spinner colour is that
            // same accent, so it would be invisible.
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.onButtonFill,
                ),
              )
            : const Text('Add', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ─── Avatar ──────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final PublicProfile? profile;
  final double size;
  final bool online;

  const _Avatar({required this.profile, required this.size, this.online = false});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final url = profile?.photoURL ?? '';
    // Dot ring is drawn in the panel colour, matching the surface behind it.
    final ring = theme.panelSurfaceColor;

    Widget face;
    if (url.isNotEmpty) {
      face = CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: theme.card),
        errorWidget: (_, __, ___) => _placeholder(theme),
      );
    } else {
      face = _placeholder(theme);
    }

    final avatar =
        ClipOval(child: SizedBox(width: size, height: size, child: face));

    if (!online) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: theme.nowPlayingAccent,
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _placeholder(AppThemeData theme) => Container(
        color: theme.card,
        child: Icon(Icons.person_outline,
            color: theme.subtext.withValues(alpha: 0.5), size: size * 0.5),
      );
}

// ─── States ──────────────────────────────────────────────────────────────────

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: CircularProgressIndicator(
        color: context.appTheme.usesModernDesign
            ? context.appTheme.subtext
            : context.appTheme.button,
      ),
    );
  }
}

/// Shared "nothing here" content for the panel body.
class _EmptyBox extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyBox({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.iconDefault),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.subtext,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.subtext, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}