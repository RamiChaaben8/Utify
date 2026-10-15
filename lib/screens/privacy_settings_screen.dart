import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/firestore_service.dart';
import '../providers/presence_provider.dart';
import '../desktop/theme/desktop_theme.dart';

class PrivacySettingsScreen extends ConsumerStatefulWidget {
  final User user;

  const PrivacySettingsScreen({super.key, required this.user});

  @override
  ConsumerState<PrivacySettingsScreen> createState() =>
      _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState
    extends ConsumerState<PrivacySettingsScreen> {
  final _service = FirestoreService();
  Map<String, bool> _privacy = const {
    'showOnlineStatus': true,
    'showActivity': true,
    'allowFriendRequests': true,
  };
  bool _loading = true;

  /// Keys with an in-flight write, so a row can't be tapped twice.
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await _service.getPublicProfile(widget.user.uid);
    if (!mounted) return;
    setState(() {
      if (profile != null) _privacy = profile.privacy;
      _loading = false;
    });
  }

  /// Each toggle writes straight through to Firestore and presence, so there
  /// is no unsaved state and nothing for a "Save" button to do.
  Future<void> _set(String key, bool value) async {
    final old = _privacy;
    final next = {...old, key: value};
    setState(() {
      _privacy = next;
      _pending.add(key);
    });
    try {
      await _service.updatePrivacy(widget.user.uid, next);
      await ref.read(presenceProvider.notifier).updatePrivacy(next);
    } catch (_) {
      if (mounted) {
        setState(() => _privacy = old);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update privacy settings.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pending.remove(key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    // The AppBar itself is themed by ThemeData.appBarTheme; without it the bar
    // sat on `surface` == `main` (invisible against the desktop shell) with a
    // lime title inherited from onSurface.
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: theme.usesModernDesign
                    ? theme.subtext
                    : theme.button,
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Changes are saved as you make them.',
                    style: TextStyle(color: theme.subtext, fontSize: 13),
                  ),
                ),
                _toggle(
                  'Show my online status',
                  'Friends can see when you are online.',
                  'showOnlineStatus',
                ),
                _toggle(
                  'Show what I am listening to',
                  'Friends can see your current track.',
                  'showActivity',
                ),
                _toggle(
                  'Allow friend requests',
                  'Let other users send you friend requests.',
                  'allowFriendRequests',
                ),
              ],
            ),
    );
  }

  Widget _toggle(String title, String subtitle, String key) {
    final theme = context.appTheme;
    return SwitchListTile(
      title: Text(title, style: TextStyle(color: theme.text)),
      subtitle: Text(subtitle, style: TextStyle(color: theme.subtext)),
      value: _privacy[key] ?? true,
      onChanged: _pending.contains(key) ? null : (value) => _set(key, value),
    );
  }
}
