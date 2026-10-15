// ============================================================
// desktop/desktop_app.dart
// Root widget for Windows — wraps DesktopShell in MaterialApp.
// ============================================================

import 'package:flutter/material.dart';

import 'shell/desktop_shell.dart';
import 'theme/desktop_theme.dart';

class DesktopApp extends StatelessWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppThemeBuilder(
      builder: (context, theme) => MaterialApp(
        title: 'Utify',
        debugShowCheckedModeBanner: false,
        theme: _buildDesktopTheme(theme),
        home: const DesktopShell(),
      ),
    );
  }

  ThemeData _buildDesktopTheme(AppThemeData t) {
    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      scaffoldBackgroundColor: t.main,
      colorScheme: ColorScheme(
        brightness: t.brightness,
        primary: t.nowPlayingAccent,
        secondary: t.button,
        surface: t.main,
        onSurface: t.text,
        onSurfaceVariant: t.subtext,
        inverseSurface: t.card,
        onInverseSurface: t.subtext,
        onPrimary: t.onButtonFill,
        onSecondary: t.onButtonFill,
        error: t.notificationError,
        onError: t.onErrorFill,
      ),
      cardColor: t.card,
      dividerColor: t.dividerColor,
      textTheme: TextTheme(
        displayLarge: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        headlineLarge: TextStyle(color: t.text, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: t.text, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(color: t.text, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: t.text, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: t.text),
        bodyMedium: TextStyle(color: t.subtext),
        labelLarge: TextStyle(color: t.text, fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.card,
        hintStyle: TextStyle(color: t.subtext),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      iconTheme: IconThemeData(
          color: t.usesModernDesign ? t.iconDefault : t.text),
      iconButtonTheme: t.usesModernDesign
          ? IconButtonThemeData(style: t.iconButtonStyle)
          : const IconButtonThemeData(),
      tabBarTheme: t.usesModernDesign
          ? TabBarThemeData(
              labelColor: t.nowPlayingAccent,
              unselectedLabelColor: t.subtext,
              indicatorColor: t.nowPlayingAccent,
            )
          : const TabBarThemeData(),
      progressIndicatorTheme: ProgressIndicatorThemeData(
          color: t.usesModernDesign ? t.subtext : t.button),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.button,
        inactiveTrackColor: t.shadow,
        thumbColor: t.text,
        overlayColor: t.button.withValues(alpha: 0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
            t.usesModernDesign ? t.scrollbarThumbColor : t.button),
        thickness: WidgetStateProperty.all(4),
        radius: const Radius.circular(2),
      ),
    );
  }
}
