import 'package:flutter_test/flutter_test.dart';
import 'package:utify/desktop/theme/app_theme.dart';

void main() {
  group('theme layout tokens', () {
    test('every theme shares the modern layout', () {
      for (final theme in AppThemeData.all) {
        expect(
          identical(theme.layoutTokens, AppLayoutTokens.modern),
          isTrue,
          reason: '${theme.name} should use AppLayoutTokens.modern',
        );
      }
    });
  });

  group('accent hue', () {
    test('Green and Red keep their button colour as the accent', () {
      expect(AppThemeData.green.nowPlayingAccent, AppThemeData.green.button);
      expect(AppThemeData.red.nowPlayingAccent, AppThemeData.red.button);
    });

    test('Verdant Night keeps lime (text) as the accent', () {
      expect(
        AppThemeData.verdantNight.nowPlayingAccent,
        AppThemeData.verdantNight.text,
      );
    });
  });
}
