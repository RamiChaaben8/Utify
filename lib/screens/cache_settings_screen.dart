// ============================================================
// screens/cache_settings_screen.dart
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/theme/desktop_theme.dart';
import '../providers/cache_settings_provider.dart';
import '../services/audio_cache_service.dart';

class CacheSettingsScreen extends ConsumerWidget {
  const CacheSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.appTheme;
    final state = ref.watch(cacheSettingsProvider);
    final notifier = ref.read(cacheSettingsProvider.notifier);

    final limitText = _limitLabel(state.limitBytes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache'),
        backgroundColor: theme.main,
        foregroundColor: theme.text,
      ),
      backgroundColor: theme.main,
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _tile(
                  context,
                  theme,
                  title: 'Current cache size',
                  subtitle: formatCacheBytes(state.totalBytes),
                ),
                const SizedBox(height: 8),
                _tile(
                  context,
                  theme,
                  title: 'Cache size limit',
                  subtitle: limitText,
                  trailing: DropdownButton<int>(
                    value: state.limitBytes,
                    dropdownColor: theme.card,
                    style: TextStyle(color: theme.text),
                    items: const [
                      DropdownMenuItem(
                        value: kCacheLimit250MB,
                        child: Text('250 MB'),
                      ),
                      DropdownMenuItem(
                        value: kCacheLimit500MB,
                        child: Text('500 MB'),
                      ),
                      DropdownMenuItem(
                        value: kCacheLimit1GB,
                        child: Text('1 GB'),
                      ),
                      DropdownMenuItem(
                        value: kCacheLimit2GB,
                        child: Text('2 GB'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) notifier.setLimit(v);
                    },
                  ),
                ),
                SwitchListTile(
                  title: Text('Cache on mobile data',
                      style: TextStyle(color: theme.text)),
                  subtitle: Text(
                    'Allow prefetching audio files over mobile data',
                    style: TextStyle(color: theme.subtext),
                  ),
                  value: state.cacheOnMobileData,
                  onChanged: notifier.setCacheOnMobileData,
                  activeColor: theme.button,
                  tileColor: theme.card,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: notifier.clearCache,
                  child: const Text('Clear cache'),
                ),
              ],
            ),
    );
  }

  Widget _tile(BuildContext context, AppThemeData theme,
          {required String title,
          required String subtitle,
          Widget? trailing}) =>
      Container(
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          title: Text(title, style: TextStyle(color: theme.text)),
          subtitle: Text(subtitle, style: TextStyle(color: theme.subtext)),
          trailing: trailing,
        ),
      );

  String _limitLabel(int bytes) {
    if (bytes >= kCacheLimit2GB) return '2 GB';
    if (bytes >= kCacheLimit1GB) return '1 GB';
    if (bytes >= kCacheLimit500MB) return '500 MB';
    return '250 MB';
  }
}
