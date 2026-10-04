// ============================================================
// desktop/settings/desktop_settings_view.dart
//
// Desktop-only settings surface, replacing the mobile
// PrivacySettingsScreen route that the account menu used to push.
//
// Full-window page: the shell gives it the entire area under the
// title bar, with no library rail, no now-playing/lyrics/queue panel
// and no player bar. Playback keeps running; only the chrome is
// suppressed.
//
// Two panes, the way desktop settings pages are laid out: a
// category rail on the left, the selected category's form on the
// right. This is the desktop idiom — no other centre view uses a
// TabBar, and the mobile screen it replaces was a single-purpose
// ListView that could not grow past three toggles.
//
// Profile editing moved here from the shell's modal AlertDialog,
// because a two-field form does not belong in a dialog.
//
// Reached as _currentView == 4.
// ============================================================

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/presence_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../theme/desktop_theme.dart';


/// Left-rail categories. [profile] and [privacy] need a signed-in user;
/// [appearance] does not, so it stays reachable in guest mode.
enum SettingsSection { profile, privacy, appearance, downloads }


class DesktopSettingsView extends ConsumerStatefulWidget {
  /// Which category opens first. Set by the account menu entry that was
  /// tapped, so "Profile" lands on Profile rather than always on the top one.
  final SettingsSection initialSection;

  const DesktopSettingsView({
    super.key,
    this.initialSection = SettingsSection.appearance,
  });

  @override
  ConsumerState<DesktopSettingsView> createState() =>
      _DesktopSettingsViewState();
}

class _DesktopSettingsViewState extends ConsumerState<DesktopSettingsView> {
  late SettingsSection _section = widget.initialSection;

  @override
  void didUpdateWidget(covariant DesktopSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Opening the account menu from inside settings asks for a different
    // starting category. The view keeps its key, so nothing else would move
    // the rail off whatever was last picked here.
    if (widget.initialSection != oldWidget.initialSection) {
      setState(() => _section = widget.initialSection);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final user = ref.watch(authServiceProvider).currentUser;

    return ColoredBox(
      // Edge-to-edge: the shell gives this the whole area under the title bar,
      // so there is no panel radius or surrounding gap to draw.
      color: theme.main,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Category rail ─────────────────────────────────────────
          SizedBox(
            width: 240,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              children: [
                // Rail heading, so the page is identifiable even when the
                // content pane is scrolled or empty (guest mode).
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      color: theme.isVerdantNightDesktop
                          ? theme.text
                          : theme.button,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _RailItem(
                  icon: Icons.person_outline,
                  label: 'Profile',
                  selected: _section == SettingsSection.profile,
                  // Guest sessions have no profile document to edit.
                  enabled: user != null,
                  onTap: () => setState(() => _section = SettingsSection.profile),
                ),
                _RailItem(
                  icon: Icons.lock_outline,
                  label: 'Privacy',
                  selected: _section == SettingsSection.privacy,
                  enabled: user != null,
                  onTap: () => setState(() => _section = SettingsSection.privacy),
                ),
                _RailItem(
                  icon: Icons.palette_outlined,
                  label: 'Appearance',
                  selected: _section == SettingsSection.appearance,
                  onTap: () =>
                      setState(() => _section = SettingsSection.appearance),
                ),
                _RailItem(
                  icon: Icons.cloud_download_outlined,
                  label: 'Downloads',
                  selected: _section == SettingsSection.downloads,
                  onTap: () =>
                      setState(() => _section = SettingsSection.downloads),
                ),
              ],
            ),
          ),

          // Hairline between rail and content.
          Container(
            width: 1,
            color: theme.dividerColor,
          ),

          // ── Content ──────────────────────────────────────────────
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(color: theme.panelSurfaceColor),
              child: switch (_section) {
                SettingsSection.profile => user == null
                    ? const _SignedOutNotice(category: 'Profile')
                    : _ProfileSection(user: user),
                SettingsSection.privacy => user == null
                    ? const _SignedOutNotice(category: 'Privacy')
                    : _PrivacySection(uid: user.uid),
                SettingsSection.appearance => const _AppearanceSection(),
                SettingsSection.downloads => const _DownloadsSection(),
              },
            ),
          ),

        ],
      ),
    );
  }
}

// ─── Rail item ───────────────────────────────────────────────────────────────

class _RailItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final active = widget.selected && widget.enabled;
    final color = !widget.enabled
        ? theme.subtext.withValues(alpha: 0.5)
        : active
            ? theme.text
            : _hovered
                ? theme.iconHover
                : theme.iconDefault;

    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(
            color: active
                // `selectedRow` is the token for "this list row is the current
                // one"; `highlight` alone reads as generic hover chrome.
                ? theme.selectedRow
                : _hovered && widget.enabled
                    ? theme.highlight
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Shared section chrome ───────────────────────────────────────────────────

/// Title + description header used at the top of each content pane.
class _SectionHeader extends StatelessWidget {
  final String title;
  final String description;

  const _SectionHeader({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.isVerdantNightDesktop ? theme.text : theme.button,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(color: theme.subtext, fontSize: 13),
        ),
      ],
    );
  }
}

/// Label + description + control, stacked left-aligned — the desktop settings
/// row shape rather than a full-width ListTile with a trailing control.
class _SettingRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget control;

  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.control,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    final field = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(color: theme.subtext, fontSize: 13),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          // Cap short controls so a toggle or field doesn't stretch the full
          // pane the way a bare ListTile would.
          constraints: const BoxConstraints(maxWidth: 420),
          child: control,
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: field,
    );
  }
}

class _SignedOutNotice extends StatelessWidget {
  final String category;

  const _SignedOutNotice({required this.category});

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_outlined, size: 52, color: theme.iconDefault),
            const SizedBox(height: 14),
            Text(
              'Sign in to change $category settings',
              style: TextStyle(
                color: theme.subtext,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Guest sessions have no account to attach these to.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.subtext, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

void _showSettingsSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
    ));
}

// ─── Profile ─────────────────────────────────────────────────────────────────

class _ProfileSection extends ConsumerStatefulWidget {
  final User user;

  const _ProfileSection({required this.user});

  @override
  ConsumerState<_ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends ConsumerState<_ProfileSection> {
  late final TextEditingController _displayName =
      TextEditingController(text: widget.user.displayName ?? '');
  late final TextEditingController _photoUrl =
      TextEditingController(text: widget.user.photoURL ?? '');
  final _formKey = GlobalKey<FormState>();

  bool _saving = false;
  String? _error;

  bool get _dirty =>
      _displayName.text.trim() != (widget.user.displayName ?? '').trim() ||
      _photoUrl.text.trim() != (widget.user.photoURL ?? '').trim();

  @override
  void initState() {
    super.initState();
    _displayName.addListener(_onChanged);
    _photoUrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _displayName
      ..removeListener(_onChanged)
      ..dispose();
    _photoUrl
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(firestoreServiceProvider).updateOwnProfile(
            user: widget.user,
            displayName: _displayName.text,
            photoURL: _photoUrl.text,
          );
      if (!mounted) return;
      setState(() => _saving = false);
      _showSettingsSnack(context, 'Profile saved.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _describe(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(38, 28, 38, 40),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              title: 'Profile',
              description:
                  'How you appear to friends. Your username is set during signup '
                  'and cannot be changed here.',
            ),
            const SizedBox(height: 30),

            // Avatar preview: the only place the photo URL's effect is visible.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AvatarPreview(
                  url: _photoUrl.text.trim(),
                  fallbackUrl: widget.user.photoURL,
                  size: 88,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.user.displayName?.isNotEmpty == true
                            ? widget.user.displayName!
                            : 'No display name yet',
                        style: TextStyle(
                          color: theme.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.user.email ?? 'Signed-in account',
                        style: TextStyle(color: theme.subtext, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            _SettingRow(
              title: 'Display name',
              subtitle: 'Shown next to your avatar and on your profile.',
              control: TextFormField(
                controller: _displayName,
                maxLength: 50,
                style: TextStyle(color: theme.text),
                decoration: InputDecoration(
                  hintText: 'Your name',
                  hintStyle: TextStyle(color: theme.subtext),
                  counterText: '',
                  filled: true,
                  fillColor: theme.card,
                  border: _inputBorder(theme),
                  enabledBorder: _inputBorder(theme),
                  focusedBorder: _inputBorder(theme, focused: true),
                ),
                validator: (value) =>
                    (value?.trim().isNotEmpty ?? false) ? null : 'Enter a display name.',
              ),
            ),

            _SettingRow(
              title: 'Profile image URL',
              subtitle: 'Paste a link to an image. Leave blank to remove it.',
              control: TextFormField(
                controller: _photoUrl,
                keyboardType: TextInputType.url,
                style: TextStyle(color: theme.text),
                decoration: InputDecoration(
                  hintText: 'https://example.com/image.jpg',
                  hintStyle: TextStyle(color: theme.subtext),
                  helperText: 'Must start with http:// or https://',
                  helperStyle: TextStyle(color: theme.subtext, fontSize: 12),
                  filled: true,
                  fillColor: theme.card,
                  border: _inputBorder(theme),
                  enabledBorder: _inputBorder(theme),
                  focusedBorder: _inputBorder(theme, focused: true),
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: theme.notificationError),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.notificationError),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.button,
                    // Label sits on the accent fill, so onButtonFill — never
                    // `text`, which is lime in Verdant Night.
                    foregroundColor: theme.onButtonFill,
                    disabledBackgroundColor: theme.highlightElevated,
                    disabledForegroundColor: theme.subtext,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 13),
                    shape: const StadiumBorder(),
                    elevation: 0,
                  ),
                  onPressed: _saving || !_dirty ? null : _save,
                  child: _saving
                      // Same reasoning as the button label: the default spinner
                      // colour is the accent, invisible on the accent fill.
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.onButtonFill,
                          ),
                        )
                      : const Text('Save changes',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 14),
                // Explains the disabled Save rather than leaving a dead button.
                if (!_saving && !_dirty)
                  Text(
                    'No changes to save',
                    style: TextStyle(color: theme.subtext, fontSize: 12),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// FirebaseAuth stringifies as a long `[firebase_auth/…]` code dump, which is
/// useless in a one-line error. Everything else already returns a usable
/// message from its own `toString`.
String _describe(Object error) => error is FirebaseAuthException
    ? (error.message ?? 'Could not save your profile.')
    : error.toString();

/// Standard field chrome: 8px corners (not the pill `searchRadius` used for
/// the search box) on a theme divider, turning accent while focused.
OutlineInputBorder _inputBorder(AppThemeData theme, {bool focused = false}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
        color: focused ? theme.button : theme.dividerColor,
      ),
    );
}

class _AvatarPreview extends StatelessWidget {
  final String url;
  final String? fallbackUrl;
  final double size;

  const _AvatarPreview({
    required this.url,
    required this.size,
    this.fallbackUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    // While the URL is being typed, fall back to the saved photo so the
    // preview does not blink to a placeholder on every keystroke.
    final effective = url.isNotEmpty ? url : (fallbackUrl ?? '');

    Widget face;
    if (effective.isEmpty) {
      face = _placeholder(theme);
    } else {
      face = CachedNetworkImage(
        imageUrl: effective,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: theme.card),
        errorWidget: (_, __, ___) => _placeholder(theme),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(width: size, height: size, child: face),
    );
  }

  Widget _placeholder(AppThemeData theme) => Container(
        color: theme.card,
        child: Icon(Icons.person,
            color: theme.subtext.withValues(alpha: 0.54), size: size * 0.45),
      );
}

// ─── Privacy ─────────────────────────────────────────────────────────────────

class _PrivacySection extends ConsumerStatefulWidget {
  final String uid;

  const _PrivacySection({required this.uid});

  @override
  ConsumerState<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<_PrivacySection> {
  Map<String, bool> _privacy = const {
    'showOnlineStatus': true,
    'showActivity': true,
    'allowFriendRequests': true,
  };

  bool _loading = true;

  /// Keys with an in-flight write, so a row can't be toggled twice.
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile =
          await ref.read(firestoreServiceProvider).getPublicProfile(widget.uid);
      if (!mounted) return;
      setState(() {
        if (profile != null) _privacy = profile.privacy;
        _loading = false;
      });
    } catch (_) {
      // Fall back to the all-on defaults rather than spinning forever; the
      // first toggle will surface the failure and roll itself back.
      if (!mounted) return;
      setState(() => _loading = false);
    }
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
      await ref.read(firestoreServiceProvider).updatePrivacy(widget.uid, next);
      await ref.read(presenceProvider.notifier).updatePrivacy(next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _privacy = old);
      _showSettingsSnack(context, 'Could not update privacy settings.');
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: theme.isVerdantNightDesktop
              ? theme.subtext
              : theme.button,
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(38, 28, 38, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Privacy',
            description:
                'What friends can see about you. Every change saves as you make '
                'it — there is nothing to submit.',
          ),
          const SizedBox(height: 30),
          _SettingRow(
            title: 'Show my online status',
            subtitle: 'Friends can see when you are online.',
            // Under its own label rather than trailing at the far right, so
            // the switch lines up with the fields in the Profile section.
            control: _InlineSwitch(
              value: _privacy['showOnlineStatus'] ?? true,
              busy: _pending.contains('showOnlineStatus'),
              onChanged: (v) => _set('showOnlineStatus', v),
            ),
          ),
          _SettingRow(
            title: 'Show what I am listening to',
            subtitle: 'Friends can see your current track.',
            control: _InlineSwitch(
              value: _privacy['showActivity'] ?? true,
              busy: _pending.contains('showActivity'),
              onChanged: (v) => _set('showActivity', v),
            ),
          ),
          _SettingRow(
            title: 'Allow friend requests',
            subtitle: 'Let other users send you friend requests.',
            control: _InlineSwitch(
              value: _privacy['allowFriendRequests'] ?? true,
              busy: _pending.contains('allowFriendRequests'),
              onChanged: (v) => _set('allowFriendRequests', v),
            ),
          ),
        ],
      ),
    );
  }
}

/// Switch with a spinner while its write is in flight, so a slow Firestore
/// round trip doesn't leave the toggle looking like it already succeeded.
class _InlineSwitch extends StatelessWidget {
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _InlineSwitch({
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;
    return SizedBox(
      height: 32,
      child: busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.isVerdantNightDesktop
                        ? theme.subtext
                        : theme.button,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Saving…',
                    style: TextStyle(color: theme.subtext, fontSize: 12)),
              ],
            )
          : Switch(
              value: value,
              onChanged: onChanged,
            ),
    );
  }
}

// ─── Appearance ──────────────────────────────────────────────────────────────

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(38, 28, 38, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Appearance',
            description: 'Pick the colour scheme the whole app uses.',
          ),
          const SizedBox(height: 30),
          ...AppThemeData.all.map(
            (candidate) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ThemeOption(
                candidate: candidate,
                selected: candidate == theme,
                onTap: () => AppThemeNotifier.instance.setTheme(candidate),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width selectable card showing each theme's own palette, rather than a
/// dropdown in a menu — easier to recognise, and it is the point of the
/// Appearance pane.
class _ThemeOption extends StatefulWidget {
  final AppThemeData candidate;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ThemeOption> createState() => _ThemeOptionState();
}

class _ThemeOptionState extends State<_ThemeOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.appTheme;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.selected
                ? theme.selectedRow
                : _hovered
                    ? theme.highlight
                    : theme.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected ? theme.button : theme.dividerColor,
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // Palette swatches from the candidate theme's own tokens.
              _Swatch(color: widget.candidate.main),
              _Swatch(color: widget.candidate.card),
              _Swatch(color: widget.candidate.button),
              _Swatch(color: widget.candidate.text),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  widget.candidate.name,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: 15,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.selected)
                // Sits on the row fill, not on an accent fill, so `text` is the
                // right token — `onAccent` is near-black in Verdant Night and
                // would vanish against the selected-row green.
                Icon(Icons.check_circle, size: 20, color: theme.text),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;

  const _Swatch({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: context.appTheme.dividerColor),
      ),
    );
  }
}

// ─── Downloads settings section ──────────────────────────────────────────────

class _DownloadsSection extends ConsumerWidget {
  const _DownloadsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl           = ref.watch(downloadProvider);
    final notifier     = ref.read(downloadProvider.notifier);
    final connectivity = ref.watch(connectivityProvider);

    final downloadQuality  = notifier.downloadQuality;
    final downloadOnMobile = notifier.downloadOnMobile;

    final totalMB = dl.totalSizeBytes / 1024 / 1024;
    final totalStr = totalMB >= 1024
        ? '${(totalMB / 1024).toStringAsFixed(1)} GB'
        : '${totalMB.toStringAsFixed(0)} MB';


    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const Text(
          'Downloads',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 24),

        // Download quality
        const Text('Download quality',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'best', label: Text('Best available')),
            ButtonSegment(value: 'compatible', label: Text('Compatible (m4a)')),
          ],
          selected: {downloadQuality},
          onSelectionChanged: (s) => notifier.setDownloadQuality(s.first),
          style: SegmentedButton.styleFrom(
            foregroundColor: Colors.white,
            selectedForegroundColor: Colors.black,
            selectedBackgroundColor: const Color(0xFF1DB954),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          downloadQuality == 'compatible'
              ? 'Only download m4a/AAC streams. May skip songs with no m4a stream.'
              : 'Download the highest bitrate stream in its original container.',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 24),

        // Download on mobile data
        SwitchListTile(
          value: downloadOnMobile,

          onChanged: (v) => notifier.setDownloadOnMobile(v),
          title: const Text('Download on mobile data',
              style: TextStyle(color: Colors.white)),
          subtitle: const Text('Off: Wi-Fi only  ·  On: allows mobile data',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          activeColor: const Color(0xFF1DB954),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),

        // Offline mode toggle
        SwitchListTile(
          value: connectivity.offlineModeEnabled,
          onChanged: (v) =>
              ref.read(connectivityProvider.notifier).setOfflineMode(v),
          title: const Text('Offline mode',
              style: TextStyle(color: Colors.white)),
          subtitle: const Text(
              'Force offline behaviour even when connected.',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          activeColor: const Color(0xFF1DB954),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(color: Colors.white12, height: 32),

        // Storage usage
        Row(
          children: [
            const Icon(Icons.storage, color: Colors.white38, size: 18),
            const SizedBox(width: 8),
            Text(
              '${dl.downloaded.length} songs · $totalStr used',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Remove all downloads
        OutlinedButton.icon(
          onPressed: dl.downloaded.isEmpty
              ? null
              : () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1E1E),
                      title: const Text('Remove all downloads?'),
                      content: const Text(
                        'All downloaded files will be deleted.',
                        style: TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Remove all',
                              style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await notifier.deleteAllDownloads();
                  }
                },
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          label: const Text('Remove all downloads',
              style: TextStyle(color: Colors.redAccent)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}