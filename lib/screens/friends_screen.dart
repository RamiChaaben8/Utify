import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';

import '../providers/auth_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/presence_provider.dart';
import '../services/firestore_service.dart';
import 'friend_profile_screen.dart';
import '../desktop/theme/desktop_theme.dart';

class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchController = TextEditingController();
  List<PublicProfile> _results = [];
  bool _searching = false;
  String? _sendingRequestUid;
  Timer? _desktopRefreshTimer;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null && ref.read(friendsProvider.notifier).uid != uid) {
        ref.read(friendsProvider.notifier).initForUser(uid);
      }
    });
    if (Platform.isWindows) {
      _desktopRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) ref.read(friendsProvider.notifier).refresh();
      });
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    _desktopRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final results =
        await ref.read(friendsProvider.notifier).search(_searchController.text);
    if (mounted) {
      setState(() {
        _results = results;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(friendsProvider);
    if (state.error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(friendsProvider).error == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(state.error!)),
        );
        ref.read(friendsProvider.notifier).clearError();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'Friends'),
            Tab(
                text:
                    'Requests${state.incomingRequests.isEmpty && state.outgoingRequests.isEmpty ? '' : ' (${state.incomingRequests.length + state.outgoingRequests.length})'}'),
            const Tab(text: 'Add Friend'),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabs,
          children: [
            _friendsList(state),
            _requestsList(state),
            _addFriend(),
          ],
        ),
      ),
    );
  }

  Widget _friendsList(FriendsState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final friends = state.accepted;
    if (friends.isEmpty) {
      return const _EmptyState(
        icon: Icons.people_outline,
        message: 'No friends yet, add someone by username.',
      );
    }
    return ListView.builder(
      itemCount: friends.length,
      itemBuilder: (_, index) => _friendTile(friends[index]),
    );
  }

  Widget _requestsList(FriendsState state) {
    final requests = [
      ...state.incomingRequests,
      ...state.outgoingRequests.where((outgoing) =>
          !state.incomingRequests.any((item) => item.id == outgoing.id)),
    ];
    if (requests.isEmpty) {
      return const _EmptyState(
        icon: Icons.mark_email_unread_outlined,
        message: 'No pending friend requests.',
      );
    }
    return ListView(
      children: requests
          .map((request) => request.requestedBy == _currentUid
              ? _outgoingRequestTile(request)
              : _requestTile(request))
          .toList(),
    );
  }

  String? get _currentUid => ref.read(friendsProvider.notifier).uid;

  Widget _addFriend() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search username',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: _searching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward),
                onPressed: _searching ? null : _search,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _results.isEmpty
                ? const _EmptyState(
                    icon: Icons.person_search,
                    message: 'Search by exact or partial username.',
                  )
                : ListView(
                    children: _results.map(_searchResultTile).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _friendTile(Friendship friendship) {
    final profile = friendship.profile;
    if (profile == null || friendship.otherUid == null) {
      return ListTile(
        leading: _avatar(profile),
        title: Text('@${profile?.username ?? 'unknown'}'),
      );
    }
    return _FriendPresenceTile(
      friendship: friendship,
      profile: profile,
    );
  }

  String _lastSeen(DateTime? lastActiveAt) {
    if (lastActiveAt == null) return '';
    final elapsed = DateTime.now().difference(lastActiveAt);
    if (elapsed.inMinutes < 1) return ' • last seen just now';
    if (elapsed.inHours < 1) return ' • last seen ${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return ' • last seen ${elapsed.inHours}h ago';
    return ' • last seen ${elapsed.inDays}d ago';
  }

  Widget _requestTile(Friendship request) {
    final profile = request.profile;
    return ListTile(
      leading: _avatar(profile),
      title: Text('@${profile?.username ?? 'unknown'}'),
      subtitle: Text(profile?.displayName ?? ''),
      trailing: Wrap(
        children: [
          IconButton(
            tooltip: 'Accept',
            icon: Icon(Icons.check, color: context.appTheme.button),
            onPressed: () => ref.read(friendsProvider.notifier).accept(request),
          ),
          IconButton(
            tooltip: 'Decline',
            icon: const Icon(Icons.close),
            onPressed: () =>
                ref.read(friendsProvider.notifier).decline(request),
          ),
        ],
      ),
    );
  }

  Widget _searchResultTile(PublicProfile profile) {
    return ListTile(
      leading: _avatar(profile),
      title: Text(profile.displayName.isEmpty
          ? '@${profile.username}'
          : profile.displayName),
      subtitle: Text('@${profile.username}'),
      trailing: FilledButton(
        onPressed: _sendingRequestUid == profile.uid
            ? null
            : () async {
                setState(() => _sendingRequestUid = profile.uid);
                final success = await ref
                    .read(friendsProvider.notifier)
                    .sendRequest(profile.uid);
                if (!mounted) return;
                setState(() => _sendingRequestUid = null);
                if (success) {
                  _tabs.animateTo(1);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content:
                          Text('Friend request sent to @${profile.username}.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } else {
                  final error = ref.read(friendsProvider).error;
                  if (error != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(error),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    ref.read(friendsProvider.notifier).clearError();
                  }
                }
              },
        child: _sendingRequestUid == profile.uid
            ? SizedBox(
                width: 18,
                height: 18,
                // Sits on the accent-filled 'Add' button; the default spinner
                // colour is that same accent, so it was invisible.
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.appTheme.onButtonFill,
                ),
              )
            : const Text('Add'),
      ),
    );
  }

  Widget _outgoingRequestTile(Friendship request) {
    final profile = request.profile;
    return ListTile(
      leading: _avatar(profile),
      title: Text('@${profile?.username ?? 'unknown'}'),
      subtitle: const Text('Request sent'),
      trailing: TextButton(
        onPressed: () => ref.read(friendsProvider.notifier).decline(request),
        child: const Text('Cancel'),
      ),
    );
  }

  Widget _avatar(PublicProfile? profile) {
    final theme = context.appTheme;
    final verdant = theme.isVerdantNightDesktop;
    if (profile?.photoURL.isNotEmpty == true) {
      return CircleAvatar(
        child: ClipOval(
          child: Image.network(
            profile!.photoURL,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Icon(Icons.person_outline,
                color: verdant ? theme.button : null),
          ),
        ),
      );
    }
    return CircleAvatar(
      backgroundColor: verdant ? theme.tabActive : null,
      child: Icon(Icons.person_outline, color: verdant ? theme.button : null),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 56,
                color: context.appTheme.subtext.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _FriendPresenceTile extends ConsumerWidget {
  final Friendship friendship;
  final PublicProfile profile;

  const _FriendPresenceTile({
    required this.friendship,
    required this.profile,
  });

  String _lastSeen(DateTime? lastActiveAt) {
    if (lastActiveAt == null) return '';
    final elapsed = DateTime.now().difference(lastActiveAt);
    if (elapsed.inMinutes < 1) return ' • last seen just now';
    if (elapsed.inHours < 1) return ' • last seen ${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return ' • last seen ${elapsed.inHours}h ago';
    return ' • last seen ${elapsed.inDays}d ago';
  }

  Widget _avatar(BuildContext context, PublicProfile? profile) {
    final theme = context.appTheme;
    final verdant = theme.isVerdantNightDesktop;
    if (profile?.photoURL.isNotEmpty == true) {
      return CircleAvatar(
        child: ClipOval(
          child: Image.network(
            profile!.photoURL,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Icon(Icons.person_outline,
                color: verdant ? theme.button : null),
          ),
        ),
      );
    }
    return CircleAvatar(
      backgroundColor: verdant ? theme.tabActive : null,
      child: Icon(Icons.person_outline, color: verdant ? theme.button : null),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final otherUid = friendship.otherUid ?? '';
    final presenceAsync = ref.watch(friendPresenceProvider(otherUid));
    final presence = presenceAsync.valueOrNull;

    final title = profile.displayName.isNotEmpty
        ? profile.displayName
        : '@${profile.username}';
    final online = presence?.isOnline == true;
    final listening = presence?.isListening == true;
    final subtitle = online
        ? presence!.activity != null
            ? '${presence.activity!['title'] ?? 'Listening'} • ${presence.activity!['artist'] ?? ''}'
            : 'Online'
        : 'Offline${_lastSeen(presence?.lastActiveAt)}';

    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          _avatar(context, profile),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: online
                    ? context.appTheme.nowPlayingAccent
                    : context.appTheme.subtext.withValues(alpha: 0.5),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text(title),
      subtitle: Row(
        children: [
          if (listening) ...[
            Icon(Icons.equalizer,
                size: 16, color: context.appTheme.nowPlayingAccent),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(subtitle, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FriendProfileScreen(profile: profile),
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'unfriend') {
            ref.read(friendsProvider.notifier).unfriend(friendship);
          } else if (value == 'block') {
            ref.read(friendsProvider.notifier).block(otherUid);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'unfriend', child: Text('Unfriend')),
          PopupMenuItem(value: 'block', child: Text('Block')),
        ],
      ),
    );
  }
}
