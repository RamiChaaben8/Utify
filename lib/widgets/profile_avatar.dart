import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../providers/guest_session_provider.dart';
import '../screens/cache_settings_screen.dart';
import '../screens/privacy_settings_screen.dart';
import '../services/firestore_service.dart';
import '../desktop/theme/desktop_theme.dart';
import 'update_dialog.dart';

class ProfileAvatar extends ConsumerWidget {
  const ProfileAvatar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final user = authState.asData?.value ??
        ref.read(authServiceProvider).currentUser;
    final theme = context.appTheme;
    return GestureDetector(
      onTap: () => showAccountMenu(context, ref),
      child: CircleAvatar(
        radius: 18,
        backgroundColor: theme.highlightElevated,
        backgroundImage:
            user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
        child: user?.photoURL == null
            ? Icon(Icons.person_outline, color: theme.iconDefault, size: 22)
            : null,
      ),
    );
  }
}

void showAccountMenu(BuildContext context, WidgetRef ref) {
  if (ref.read(guestSessionProvider)) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Guest mode'),
        content: const Text(
            'Would you like to leave guest mode and go to the sign-in page?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Stay as guest'),
          ),
          FilledButton(
            onPressed: () async {
              await ref.read(guestSessionProvider.notifier).leaveGuest();
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Go to sign in'),
          ),
        ],
      ),
    );
    return;
  }

  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close account menu',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, animation, secondaryAnimation) =>
        _AccountMenuPanel(ref: ref),
    transitionBuilder: (ctx, animation, secondaryAnimation, child) =>
        SlideTransition(
      position: Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
          .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

// ─── Account menu panel ───────────────────────────────────────────────────────
//
// Extracted as a StatefulWidget so:
//   1. Its BuildContext is owned by the overlay entry and has a clean lifetime.
//   2. Theme is read from its own context — no dependency on the outer context
//      that launched showGeneralDialog (which may get deactivated during async
//      Firebase calls like user.updatePhotoURL()).
//   3. The Edit Profile flow lives entirely within this widget's context tree,
//      so Navigator.pop and ScaffoldMessenger calls are always valid.

class _AccountMenuPanel extends ConsumerStatefulWidget {
  final WidgetRef ref;
  const _AccountMenuPanel({required this.ref});

  @override
  ConsumerState<_AccountMenuPanel> createState() => _AccountMenuPanelState();
}

class _AccountMenuPanelState extends ConsumerState<_AccountMenuPanel> {
  @override
  Widget build(BuildContext context) {
    final user = ref.read(authServiceProvider).currentUser;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final panelWidth = (screenWidth * 0.84).clamp(0.0, 360.0).toDouble();
    final theme = context.appTheme;

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: theme.card,
        elevation: 20,
        child: SizedBox(
          width: panelWidth,
          height: double.infinity,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ──────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 25,
                      backgroundImage: user?.photoURL?.isNotEmpty == true
                          ? NetworkImage(user!.photoURL!)
                          : null,
                      child: user?.photoURL?.isNotEmpty == true
                          ? null
                          : Icon(Icons.person_outline,
                              color: theme.iconDefault),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.displayName?.isNotEmpty == true
                                ? user!.displayName!
                                : 'Utify account',
                            style: TextStyle(
                                color: theme.text,
                                fontSize: 16,
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (user?.email != null)
                            Text(user!.email!,
                                style: TextStyle(
                                    color: theme.subtext, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, color: theme.iconDefault),
                    ),
                  ]),
                ),

                Divider(height: 1, color: theme.dividerColor),

                // ── Menu items ───────────────────────────────────────────────
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android)
                        ListTile(
                          leading: Icon(Icons.system_update_alt,
                              color: theme.iconDefault),
                          title: Text('Check for Updates',
                              style: TextStyle(color: theme.text)),
                          onTap: () {
                            Navigator.pop(context);
                            showUpdateDialog(context, ref);
                          },
                        ),
                      ListTile(
                        leading: Icon(Icons.edit_outlined,
                            color: theme.iconDefault),
                        title: Text('Edit Profile',
                            style: TextStyle(color: theme.text)),
                        onTap: () => _openEditProfile(context),
                      ),
                      ListTile(
                        leading: Icon(Icons.lock_outline,
                            color: theme.iconDefault),
                        title: Text('Privacy',
                            style: TextStyle(color: theme.text)),
                        onTap: () {
                          Navigator.pop(context);
                          final u = ref.read(authServiceProvider).currentUser;
                          if (u != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PrivacySettingsScreen(user: u),
                              ),
                            );
                          }
                        },
                      ),
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android)
                        ListTile(
                          leading: Icon(Icons.sd_storage_outlined,
                              color: theme.iconDefault),
                          title: Text('Cache & storage',
                              style: TextStyle(color: theme.text)),
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const CacheSettingsScreen(),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),

                Divider(height: 1, color: theme.dividerColor),

                // ── Sign out ─────────────────────────────────────────────────
                ListTile(
                  leading:
                      Icon(Icons.logout, color: theme.notificationError),
                  title: Text(
                    'Sign Out',
                    style: TextStyle(
                      color: theme.notificationError,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    await ref
                        .read(playerProvider.notifier)
                        .pause()
                        .catchError((_) {});
                    await ref.read(authServiceProvider).signOut();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openEditProfile(BuildContext panelContext) async {
    // Remove the panel route immediately with NO exit animation.
    // rootNavigator: true pops the topmost route (the showGeneralDialog overlay)
    // and removes it from the tree synchronously in the same frame, bypassing
    // the 260ms slide-out. Without this, the panel stays alive during the
    // animation window — long enough for Firebase userChanges() to fire and
    // AuthGate to rebuild, deactivating a context that still has InheritedWidget
    // dependents registered ('_dependents.isEmpty' assertion).

    // Capture navigator/messenger BEFORE popping — panelContext is invalid after.
    final navigator = Navigator.of(panelContext, rootNavigator: false);
    final messenger = ScaffoldMessenger.of(panelContext);
    Navigator.of(panelContext, rootNavigator: true).pop();

    final user = ref.read(authServiceProvider).currentUser;
    if (user == null) return;

    // FIX: Controllers are now owned by _EditProfileDialogState and disposed in
    // its dispose() method — NOT here in _openEditProfile.
    //
    // Previously the controllers were created here and disposed immediately after
    // showDialog() returned. On Android, Navigator.pop() inside _save() removes
    // the route but the soft keyboard is still animating closed for a few frames.
    // During those frames, MediaQuery.viewInsets keeps changing, causing the
    // framework to try to rebuild the TextFields (which had registered themselves
    // as InheritedWidget dependents). Finding an already-disposed controller, it
    // threw the '_dependents.isEmpty' assertion. On Windows there is no soft
    // keyboard, so the race never occurred — hence the Android-only failure.
    //
    // By letting _EditProfileDialogState own and dispose the controllers in
    // State.dispose(), Flutter guarantees disposal only happens after every
    // animation frame that could possibly reference them has completed.
    await showDialog<bool>(
      context: navigator.context,
      builder: (editCtx) => _EditProfileDialog(
        initialName: user.displayName ?? '',
        initialPhoto: user.photoURL ?? '',
        user: user,
        // Called only for Firebase errors after the dialog has already popped.
        onError: (msg) {
          messenger.showSnackBar(SnackBar(content: Text(msg)));
        },
      ),
    );
    // authStateProvider is a StreamProvider on userChanges — it updates itself.
  }
}

// ─── Edit profile dialog ──────────────────────────────────────────────────────

class _EditProfileDialog extends StatefulWidget {
  final String initialName;
  final String initialPhoto;
  final User user;
  // Called only for Firebase errors that occur after the dialog has already
  // popped itself. Validation errors are shown inside the dialog.
  final void Function(String) onError;

  const _EditProfileDialog({
    required this.initialName,
    required this.initialPhoto,
    required this.user,
    required this.onError,
  });

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  // Controllers are owned here and disposed in dispose() — never manually from
  // outside — so they always outlive every animation frame that may still
  // reference them after Navigator.pop() is called from _save().
  late final TextEditingController _nameController;
  late final TextEditingController _photoController;
  bool _saving = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _photoController = TextEditingController(text: widget.initialPhoto);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _photoController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    debugPrint('[EditProfile] _save() started');

    // Dismiss the soft keyboard BEFORE reading controller values and popping.
    // On Android, the keyboard-dismiss animation fires a series of MediaQuery
    // notifications for viewInsets. If those arrive while the dialog route is
    // being unmounted, they trigger a rebuild of the TextFields via their
    // InheritedWidget registrations, which hits the '_dependents.isEmpty'
    // assertion. Calling unfocus() here starts the keyboard animation early —
    // before Navigator.pop() — narrowing the race window to near-zero.
    FocusScope.of(context).unfocus();

    final trimmedName = _nameController.text.trim();
    final trimmedPhoto = _photoController.text.trim();

    // Validate synchronously and show error inside the dialog.
    if (trimmedName.isEmpty) {
      setState(() => _validationError = 'Display name cannot be empty.');
      return;
    }
    if (trimmedPhoto.isNotEmpty) {
      final uri = Uri.tryParse(trimmedPhoto);
      if (uri == null ||
          !uri.hasAuthority ||
          !['http', 'https'].contains(uri.scheme.toLowerCase())) {
        setState(() =>
            _validationError = 'Image URL must start with http:// or https://.');
        return;
      }
    }

    setState(() {
      _saving = true;
      _validationError = null;
    });

    // CRITICAL: Pop the dialog synchronously BEFORE any Firebase call.
    // user.updatePhotoURL / updateDisplayName fire userChanges() which causes
    // AuthGate to rebuild. If this dialog is still mounted at that moment,
    // Flutter finds contexts with active InheritedWidget dependents being
    // deactivated and throws '_dependents.isEmpty'.
    // By popping first the dialog context is fully removed from the tree
    // before the Firebase SDK emits anything.
    if (mounted) Navigator.pop(context, true);

    try {
      await FirestoreService().updateOwnProfile(
        user: widget.user,
        displayName: trimmedName,
        photoURL: trimmedPhoto,
      );
      debugPrint('[EditProfile] _save() completed successfully');
    } catch (error) {
      // Dialog is already gone — report via callback so caller can show snackbar.
      debugPrint('[EditProfile] _save() error: $error');
      widget.onError('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Profile'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            maxLength: 50,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          TextField(
            controller: _photoController,
            keyboardType: TextInputType.url,
            decoration:
                const InputDecoration(labelText: 'Profile image URL'),
          ),
          if (_validationError != null) ...[
            const SizedBox(height: 8),
            Text(
              _validationError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
