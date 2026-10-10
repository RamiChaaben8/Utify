import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import '../providers/auth_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/listen_party_provider.dart';
import '../providers/collaboration_invites_provider.dart';
import '../desktop/theme/desktop_theme.dart';

class ListenPartyControls extends ConsumerStatefulWidget {
  final bool showLabel;

  const ListenPartyControls({super.key, this.showLabel = false});

  @override
  ConsumerState<ListenPartyControls> createState() =>
      _ListenPartyControlsState();
}

class _ListenPartyControlsState extends ConsumerState<ListenPartyControls> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) ref.read(listenPartyProvider.notifier).initForUser(uid);
    });
  }

  Future<void> _open() async {
    if (Platform.isWindows) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Listen parties are temporarily unavailable on Windows because of a Firebase plugin crash.',
          ),
        ),
      );
      return;
    }
    final controller = TextEditingController();
    final uid = ref.read(authServiceProvider).currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to use Listen Together.')),
      );
      return;
    }
    ref.read(listenPartyProvider.notifier).initForUser(uid);

    Future<void> run(Future<void> Function() action) async {
      await action();
      if (!mounted) return;
      final error = ref.read(listenPartyProvider).error;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor:
                AppThemeScope.maybeOf(context)?.notificationError ??
                    Colors.redAccent,
          ),
        );
        ref.read(listenPartyProvider.notifier).clearError();
      }
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
          final theme = AppThemeScope.maybeOf(context);
          final partyState = ref.watch(listenPartyProvider);
          final friends = ref.watch(friendsProvider).accepted;
          return AlertDialog(
            backgroundColor: theme?.card,
            title: Text(
              partyState.party == null ? 'Listen Together' : 'Party',
              style: TextStyle(color: theme?.text),
            ),
            content: partyState.party == null
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Create a party or join with an ID.'),
                    TextField(
                      controller: controller,
                      onChanged: (_) => setDialogState(() {}),
                      style: TextStyle(color: theme?.text ?? Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Party ID (to join)',
                        labelStyle: TextStyle(color: theme?.subtext),
                        hintStyle: TextStyle(color: theme?.subtext),
                      ),
                    ),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    SelectableText('Party ID: ${partyState.party!.id}'),
                    Text('${partyState.party!.memberUids.length}/8 members'),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Invite a friend'),
                    ),
                    if (friends.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Add friends first to invite them.'),
                      )
                    else
                      ...friends.map((friend) {
                        final otherUid = friend.otherUid;
                        final profile = friend.profile;
                        if (otherUid == null) return const SizedBox.shrink();
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 16,
                            child: profile?.photoURL.isNotEmpty == true
                                ? ClipOval(child: Image.network(
                                    profile!.photoURL,
                                    width: 32,
                                    height: 32,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.person, size: 16),
                                  ))
                                : const Icon(Icons.person, size: 16),
                          ),
                          title: Text(
                            profile?.displayName.trim().isNotEmpty == true
                                ? profile!.displayName
                                : profile?.username.trim().isNotEmpty == true
                                    ? '@${profile!.username}'
                                    : otherUid,
                          ),
                          subtitle: Text('@${profile?.username ?? otherUid}'),
                          trailing: IconButton(
                            tooltip: 'Invite',
                            icon: const Icon(Icons.person_add_alt_1),
                            onPressed: () async {
                              await ref
                                  .read(listenPartyProvider.notifier)
                                  .invite(otherUid);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Invitation sent to ${profile?.displayName ?? 'friend'}',
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        );
                      }),
                  ]),
            actions: [
              if (partyState.party == null) ...[
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    run(() => ref.read(listenPartyProvider.notifier).create());
                  },
                  child: const Text('Create'),
                ),
                TextButton(
                  onPressed: controller.text.trim().isEmpty
                      ? null
                      : () {
                          Navigator.pop(context);
                          run(() => ref
                              .read(listenPartyProvider.notifier)
                              .join(controller.text.trim()));
                        },
                  child: const Text('Join'),
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ref.read(listenPartyProvider.notifier).leave();
                  },
                  child: const Text('Leave'),
                ),
              ],
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close')),
            ],
          );
        }),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final partyState = ref.watch(listenPartyProvider);
    final party = partyState.party;
    final theme = AppThemeScope.maybeOf(context);
    final label = party == null
        ? 'Listen together'
        : 'Party (${party.memberUids.length}/8)';
    final icon = Icon(
      party == null ? Icons.headphones_outlined : Icons.headphones,
      color: party == null ? null : theme?.nowPlayingAccent ?? const Color(0xFF1DB954),
    );
    if (widget.showLabel) {
      return OutlinedButton.icon(
        icon: icon,
        label: Text(label),
        onPressed: _open,
      );
    }
    return Tooltip(
      message: label,
      child: IconButton(icon: icon, onPressed: _open),
    );
  }
}

class PartyInviteButton extends ConsumerStatefulWidget {
  const PartyInviteButton({super.key});

  @override
  ConsumerState<PartyInviteButton> createState() => _PartyInviteButtonState();
}

class _PartyInviteButtonState extends ConsumerState<PartyInviteButton> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows) return;
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) {
        ref.read(listenPartyProvider.notifier).initForUser(uid);
      }
    });
  }

  Future<void> _openInvites() async {
    final invites = ref.read(listenPartyProvider).invites;
    final playlistInvites = ref.read(collaborationInvitesProvider);
    if (invites.isEmpty && playlistInvites.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No invitations.')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.appTheme.card,
        title: Text('Invitations',
            style: TextStyle(color: dialogContext.appTheme.text)),
        content: SizedBox(
          width: 460,
          child: ListView(
            shrinkWrap: true,
            children: [
              ...invites.map(
                (invite) => ListTile(
                  leading: const Icon(Icons.headphones_outlined),
                  title: Text(invite.partyName),
                  subtitle: Text('${invite.fromName} invited you to listen'),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          ref
                              .read(listenPartyProvider.notifier)
                              .acceptInvite(invite);
                        },
                        child: const Text('Accept'),
                      ),
                      IconButton(
                        tooltip: 'Decline',
                        icon: const Icon(Icons.close),
                        onPressed: () => ref
                            .read(listenPartyProvider.notifier)
                            .declineInvite(invite),
                      ),
                    ],
                  ),
                ),
              ),
              ...playlistInvites.map(
                (invite) => ListTile(
                  leading: const Icon(Icons.queue_music_outlined),
                  title: Text(invite.playlistName),
                  subtitle:
                      Text('${invite.fromName} invited you to collaborate'),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          await ref
                              .read(collaborationInvitesProvider.notifier)
                              .accept(invite);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Joined "${invite.playlistName}" playlist.'),
                              ),
                            );
                          }
                        },
                        child: const Text('Accept'),
                      ),
                      IconButton(
                        tooltip: 'Decline',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          await ref
                              .read(collaborationInvitesProvider.notifier)
                              .decline(invite);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(listenPartyProvider).invites.length +
        ref.watch(collaborationInvitesProvider).length;
    final theme = AppThemeScope.maybeOf(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: 'Invitations',
          icon: const Icon(Icons.notifications_none),
          onPressed: _openInvites,
        ),
        if (count > 0)
          Positioned(
            right: 5,
            top: 5,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                // `notification` is the same bright green as `button` in
                // Verdant Night, so there was no hue left to read the count
                // against. Amber marks it as an alert and clears the accent.
                color: theme?.warning ?? const Color(0xFFFFA000),
                shape: BoxShape.circle,
              ),
              child: Text(
                count > 9 ? '9+' : '$count',
                style: const TextStyle(
                  fontSize: 9,
                  // Amber takes near-black in every theme (white is ~2:1).
                  color: Colors.black,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
