import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../desktop/theme/desktop_theme.dart';
import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/guest_session_provider.dart';

class AddToPlaylistSheet extends ConsumerWidget {
  final Song song;

  const AddToPlaylistSheet({super.key, required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final playlists = library.playlists;
    final theme = context.appTheme;

    return Container(
      color: theme.card,
      padding: const EdgeInsets.only(top: 16, bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Add to Playlist',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: theme.text)),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(Icons.add, color: theme.iconDefault),
            title: Text('Create New Playlist',
                style: TextStyle(color: theme.text)),
            onTap: () {
              Navigator.pop(context);
              _showCreatePlaylistDialog(context, ref);
            },
          ),
          Divider(color: theme.dividerColor),
          if (playlists.isEmpty)
            Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No playlists yet',
                    style: TextStyle(color: theme.subtext)))
          else
            // Use the Playlist object directly — not a list index
            ...playlists.map((pl) => ListTile(
                  leading: Icon(Icons.queue_music, color: theme.iconDefault),
                  title: Text(pl.name, style: TextStyle(color: theme.text)),
                  onTap: () {
                    ref
                        .read(libraryProvider.notifier)
                        .addSongToPlaylistObj(pl, song);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Added to ${pl.name}')));
                  },
                )),
        ],
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog(
      BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    var visibility = 'private';
    var collaborative = false;
    final theme = context.appTheme;
    final isGuest = ref.read(guestSessionProvider);
    try {
      await showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
                  backgroundColor: theme.card,
                  title:
                      Text('New Playlist', style: TextStyle(color: theme.text)),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      style: TextStyle(color: theme.text),
                      decoration: InputDecoration(
                        hintText: 'Playlist name',
                        hintStyle: TextStyle(color: theme.subtext),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: visibility,
                      decoration: InputDecoration(labelText: 'Privacy'),
                      items: const [
                        DropdownMenuItem(
                            value: 'private', child: Text('Private')),
                        DropdownMenuItem(
                            value: 'friends', child: Text('Friends')),
                        DropdownMenuItem(
                            value: 'public', child: Text('Public')),
                      ],
                      onChanged: (value) =>
                          setState(() => visibility = value ?? 'private'),
                    ),
                    if (!isGuest)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: collaborative,
                        title: Text('Collaborative playlist',
                            style: TextStyle(color: theme.text)),
                        onChanged: (value) =>
                            setState(() => collaborative = value ?? false),
                      ),
                  ]),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Cancel',
                          style: TextStyle(color: theme.subtext)),
                    ),
                    TextButton(
                      onPressed: () {
                        final name = controller.text.trim();
                        if (name.isEmpty) return;
                        ref
                            .read(libraryProvider.notifier)
                            .createPlaylistWithSongs(
                              name,
                              [song],
                              visibility: visibility,
                              collaborative: collaborative,
                            );
                        Navigator.pop(ctx);
                      },
                      child:
                          Text('Create', style: TextStyle(color: theme.button)),
                    ),
                  ],
                )),
      );
    } finally {
      controller.dispose();
    }
  }
}
