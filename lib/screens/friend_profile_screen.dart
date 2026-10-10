import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/artwork_cache_manager.dart';
import '../models/playlist.dart';
import '../providers/library_provider.dart';
import '../screens/playlist_screen.dart';
import '../services/firestore_service.dart';

class FriendProfileScreen extends ConsumerStatefulWidget {
  final PublicProfile profile;

  const FriendProfileScreen({super.key, required this.profile});

  @override
  ConsumerState<FriendProfileScreen> createState() =>
      _FriendProfileScreenState();
}

class _FriendProfileScreenState extends ConsumerState<FriendProfileScreen> {
  late Future<List<Playlist>> _playlists;

  @override
  void initState() {
    super.initState();
    _playlists = FirestoreService().getFriendPlaylists(widget.profile.uid);
  }

  Future<void> _saveCopy(Playlist playlist) async {
    await ref.read(libraryProvider.notifier).createPlaylistWithSongs(
          '${playlist.name} (copy)',
          playlist.songs,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved a private copy to your library.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Friend profile')),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<Playlist>>(
          future: _playlists,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  'Could not load playlists. Check your connection and try again.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            final playlists = snapshot.data ?? const <Playlist>[];
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ProfileHeader(profile: profile),
                const SizedBox(height: 24),
                Text(
                  '${profile.displayName.isEmpty ? '@${profile.username}' : profile.displayName}\'s playlists',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (playlists.isEmpty)
                  const Text('No public or friends-only playlists yet.')
                else
                  ...playlists.map(_playlistTile),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _playlistTile(Playlist playlist) {
    return Card(
      child: ListTile(
        leading: playlist.coverThumbnail?.isNotEmpty == true
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: playlist.coverThumbnail!,
                  cacheManager: ArtworkCacheManager.instance,
                  memCacheWidth: (52 * MediaQuery.devicePixelRatioOf(context)).round(),
                  memCacheHeight: (52 * MediaQuery.devicePixelRatioOf(context)).round(),
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                ),
              )
            : const SizedBox(
                width: 52,
                height: 52,
                child: Icon(Icons.queue_music),
              ),
        title: Text(playlist.name),
        subtitle: Text(
          '${playlist.songs.length} songs • ${playlist.visibility}',
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PlaylistScreen(
              title: playlist.name,
              songs: playlist.songs,
              playlist: playlist,
            ),
          ),
        ),
        trailing: IconButton(
          tooltip: 'Save a private copy',
          icon: const Icon(Icons.playlist_add),
          onPressed: () => _saveCopy(playlist),
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final PublicProfile profile;

  const _ProfileHeader({required this.profile});

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.isEmpty
        ? '@${profile.username}'
        : profile.displayName;
    return Row(
      children: [
        profile.photoURL.isNotEmpty
            ? CircleAvatar(
                radius: 36,
                backgroundImage: CachedNetworkImageProvider(profile.photoURL),
              )
            : const CircleAvatar(
                radius: 36,
                child: Icon(Icons.person, size: 34),
              ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('@${profile.username}'),
            ],
          ),
        ),
      ],
    );
  }
}
