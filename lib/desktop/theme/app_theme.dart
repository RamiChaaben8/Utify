import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

bool get isDesktopLayout =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

class AppLayoutTokens {
  final double sidebarWidth;
  final double sidebarWidthRatio;
  final double sidebarMinWidth;
  final double sidebarMaxWidth;
  final double nowPlayingWidth;
  final double nowPlayingWidthRatio;
  final double nowPlayingMinWidth;
  final double nowPlayingMaxWidth;
  final double panelGap;
  final double panelRadius;
  final double topBarHeight;
  final double libraryRowHeight;
  final double libraryThumbnailSize;
  final double libraryThumbnailRadius;
  final double homeCardSize;
  final double homeCardGap;
  final double sectionGap;
  final double cardRadius;
  final double lyricsCardRadius;
  final double searchHeight;
  final double searchRadius;
  final double playButtonSize;
  final double homeCardPlayButtonSize;
  final double progressTrackHeight;
  final double progressRowPadding;
  final double playerBarHeight;
  final double playerControlsHeight;
  final double dailyMixBadgeOpacity;
  final Color? dailyMixBadgeBackground;
  final Color? dailyMixBadgeForeground;
  final bool squareNowPlayingArt;

  const AppLayoutTokens({
    required this.sidebarWidth,
    required this.sidebarWidthRatio,
    required this.sidebarMinWidth,
    required this.sidebarMaxWidth,
    required this.nowPlayingWidth,
    required this.nowPlayingWidthRatio,
    required this.nowPlayingMinWidth,
    required this.nowPlayingMaxWidth,
    required this.panelGap,
    required this.panelRadius,
    required this.topBarHeight,
    required this.libraryRowHeight,
    required this.libraryThumbnailSize,
    required this.libraryThumbnailRadius,
    required this.homeCardSize,
    required this.homeCardGap,
    required this.sectionGap,
    required this.cardRadius,
    required this.lyricsCardRadius,
    required this.searchHeight,
    required this.searchRadius,
    required this.playButtonSize,
    required this.homeCardPlayButtonSize,
    required this.progressTrackHeight,
    required this.progressRowPadding,
    required this.playerBarHeight,
    required this.playerControlsHeight,
    required this.dailyMixBadgeOpacity,
    this.dailyMixBadgeBackground,
    this.dailyMixBadgeForeground,
    required this.squareNowPlayingArt,
  });

  static const defaults = AppLayoutTokens(
    sidebarWidth: 300,
    sidebarWidthRatio: 0,
    sidebarMinWidth: 300,
    sidebarMaxWidth: 300,
    nowPlayingWidth: 380,
    nowPlayingWidthRatio: 0,
    nowPlayingMinWidth: 380,
    nowPlayingMaxWidth: 380,
    panelGap: 8,
    panelRadius: 12,
    topBarHeight: 64,
    libraryRowHeight: 60,
    libraryThumbnailSize: 48,
    libraryThumbnailRadius: 6,
    homeCardSize: 172,
    homeCardGap: 16,
    sectionGap: 24,
    cardRadius: 8,
    lyricsCardRadius: 12,
    searchHeight: 40,
    searchRadius: 999,
    playButtonSize: 52,
    homeCardPlayButtonSize: 46,
    progressTrackHeight: 3,
    progressRowPadding: 16,
    playerBarHeight: 92,
    playerControlsHeight: 76,
    dailyMixBadgeOpacity: 1,
    squareNowPlayingArt: false,
  );

  static const modern = AppLayoutTokens(
    sidebarWidth: 0,
    sidebarWidthRatio: 0.22,
    sidebarMinWidth: 360,
    sidebarMaxWidth: 430,
    nowPlayingWidth: 0,
    nowPlayingWidthRatio: 0.22,
    nowPlayingMinWidth: 360,
    nowPlayingMaxWidth: 430,
    panelGap: 8,
    panelRadius: 8,
    topBarHeight: 62,
    libraryRowHeight: 64,
    libraryThumbnailSize: 48,
    libraryThumbnailRadius: 4,
    homeCardSize: 172,
    homeCardGap: 24,
    sectionGap: 32,
    cardRadius: 8,
    lyricsCardRadius: 12,
    searchHeight: 40,
    searchRadius: 999,
    playButtonSize: 44,
    homeCardPlayButtonSize: 48,
    progressTrackHeight: 4,
    progressRowPadding: 16,
    playerBarHeight: 88,
    playerControlsHeight: 72,
    dailyMixBadgeOpacity: 0.7,
    dailyMixBadgeBackground: Color(0xB3000000),
    dailyMixBadgeForeground: Color(0xFFFFFFFF),
    squareNowPlayingArt: false,
  );

  double sidebarWidthFor(double screenWidth) => sidebarWidthRatio == 0
      ? sidebarWidth
      : (screenWidth * sidebarWidthRatio)
          .clamp(sidebarMinWidth, sidebarMaxWidth)
          .toDouble();

  double nowPlayingWidthFor(double screenWidth) => nowPlayingWidthRatio == 0
      ? nowPlayingWidth
      : (screenWidth * nowPlayingWidthRatio)
          .clamp(nowPlayingMinWidth, nowPlayingMaxWidth)
          .toDouble();
}

class AppThemeData {
  final String name;
  final Color main;
  final Color sidebar;
  final Color player;
  final Color card;
  final Color text;
  final Color subtext;
  final Color button;
  final Color buttonActive;
  final Color selectedRow;
  final Color highlight;
  final Color highlightElevated;
  final Color shadow;
  final Color notification;
  final Color notificationError;
  final Color warning;
  final Color tabActive;
  final Color misc;

  /// Foreground for [button]/[buttonActive] fills — i.e. the colour of a
  /// label sitting on the accent pill. Never use [text] here: under Verdant
  /// Night `text` is lime, so lime-on-lime would be the result.
  final Color onButtonFill;

  /// Foreground for [notificationError] fills (destructive confirm buttons).
  final Color onErrorFill;

  /// Accent hue for text and glyphs that should pop — headings, active rows and
  /// the playing indicator. Green and Red keep their accent in [button];
  /// Verdant Night keeps it in [text] (lime), so reading [button] there gives
  /// the wrong hue.
  final Color highlightAccent;

  final Color? lyricsCard;
  final Color? dividerToken;
  final Color? scrollbarToken;
  final Color? headerGradientToken;
  final AppLayoutTokens layoutTokens;

  const AppThemeData({
    required this.name,
    required this.main,
    required this.sidebar,
    required this.player,
    required this.card,
    required this.text,
    required this.subtext,
    required this.button,
    required this.buttonActive,
    required this.selectedRow,
    required this.highlight,
    required this.highlightElevated,
    required this.shadow,
    required this.notification,
    required this.notificationError,
    required this.warning,
    required this.onButtonFill,
    required this.onErrorFill,
    required this.highlightAccent,
    required this.tabActive,
    required this.misc,
    this.lyricsCard,
    this.dividerToken,
    this.scrollbarToken,
    this.headerGradientToken,
    this.layoutTokens = AppLayoutTokens.defaults,
  });

  Color get border => shadow;
  Color get bgColor => main;
  Color get panelColor => usesModernDesign ? sidebar : main;
  Color get panelSurfaceColor => usesModernDesign ? sidebar : main;
  Color get panelLight => card;
  Color get cardColor => card;
  Color get textPrimary => text;
  Color get textSecondary => subtext;
  Color get accent => button;

  /// Accent for "something is playing / active right now" — the playing song
  /// title, the play/pause glyph, headings and highlighted rows.
  ///
  /// Alias of [highlightAccent]: the same colour as [accent] in Green and Red,
  /// lime ([text]) in Verdant Night.
  Color get nowPlayingAccent => highlightAccent;

  Brightness get brightness => ThemeData.estimateBrightnessForColor(main);
  Color get lyricsCardColor => lyricsCard ?? card;
  Color get dividerColor => dividerToken ?? shadow;
  Color get scrollbarThumbColor => scrollbarToken ?? subtext;
  Color get headerGradientColor => headerGradientToken ?? shadow;
  Color get iconDefault => usesModernDesign ? subtext : text;
  Color get iconHover => usesModernDesign ? const Color(0xFFFFFFFF) : text;
  ButtonStyle get iconButtonStyle => ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.any(
                (state) =>
                    state == WidgetState.hovered ||
                    state == WidgetState.focused ||
                    state == WidgetState.pressed)
            ? iconHover
            : iconDefault),
      );
  Color get lyricsLabelColor =>
      usesModernDesign ? const Color(0xB3FFFFFF) : button;
  Color get lyricsActiveLineColor =>
      usesModernDesign ? const Color(0xFFFFFFFF) : text;
  Color get lyricsInactiveLineColor => usesModernDesign
      ? const Color(0x8CFFFFFF)
      : text.withValues(alpha: 0.38);
  Color get playIconColor =>
      usesModernDesign ? const Color(0xFF121212) : text;

  /// Label/icon colour for anything painted onto a [button]-coloured fill.
  /// Alias of [onButtonFill] kept for call sites that read better as
  /// "the colour that goes on the accent".
  Color get onAccent => onButtonFill;
  Color iconColor(Color legacy, {bool hovered = false}) =>
      usesModernDesign ? (hovered ? iconHover : iconDefault) : legacy;
  AppLayoutTokens get layout =>
      isDesktopLayout ? layoutTokens : AppLayoutTokens.defaults;
  bool get usesModernDesign =>
      isDesktopLayout && identical(layoutTokens, AppLayoutTokens.modern);

  static const green = AppThemeData(
    name: 'Green',
    main: Color(0xFF0F0F0F),
    sidebar: Color(0xFF121212),
    player: Color(0xFF0F0F0F),
    card: Color(0xFF282828),
    text: Color(0xFFFFFFFF),
    subtext: Color(0xFFB3B3B3),
    button: Color(0xFF1DB954),
    buttonActive: Color(0xFF1ED760),
    selectedRow: Color(0xFF1A2A1A),
    highlight: Color(0xFF2A2A2A),
    highlightElevated: Color(0xFF333333),
    shadow: Color(0xFF333333),
    notification: Color(0xFF1DB954),
    notificationError: Color(0xFFE8173A),
    warning: Color(0xFFFFA000),
    onButtonFill: Color(0xFF0F0F0F),
    onErrorFill: Color(0xFFFFFFFF),
    highlightAccent: Color(0xFF1DB954),
    tabActive: Color(0xFF1A3321),
    misc: Color(0xFF7B4FE9),
    layoutTokens: AppLayoutTokens.modern,
  );

  static const red = AppThemeData(
    name: 'Red',
    main: Color(0xFF0D0808),
    sidebar: Color(0xFF130A0A),
    player: Color(0xFF0D0808),
    card: Color(0xFF2A1515),
    text: Color(0xFFFFFFFF),
    subtext: Color(0xFFB3A3A3),
    button: Color(0xFFE8173A),
    buttonActive: Color(0xFFFF3657),
    selectedRow: Color(0xFF32151A),
    highlight: Color(0xFF3A2020),
    highlightElevated: Color(0xFF4A2929),
    shadow: Color(0xFF3D2020),
    notification: Color(0xFFE8173A),
    notificationError: Color(0xFFFFA000),
    warning: Color(0xFFFFA000),
    onButtonFill: Color(0xFFFFFFFF),
    onErrorFill: Color(0xFF1A0A00),
    highlightAccent: Color(0xFFE8173A),
    tabActive: Color(0xFF4A1C27),
    misc: Color(0xFFE08A3E),
    layoutTokens: AppLayoutTokens.modern,
  );

  static const verdantNight = AppThemeData(
    name: 'Verdant Night',
    main: Color(0xFF121212),
    sidebar: Color(0xFF1C1C1C),
    player: Color(0xFF1C1C1C),
    card: Color(0xFF262626),
    text: Color(0xFF7FD13B),
    subtext: Color(0xFFB3B3B3),
    button: Color(0xFF1ED760),
    buttonActive: Color(0xFF1ED760),
    selectedRow: Color(0xFF2A3D22),
    highlight: Color(0xFF2A2A2A),
    highlightElevated: Color(0xFF262626),
    shadow: Color(0xFF333333),
    notification: Color(0xFF1ED760),
    notificationError: Color(0xFFE8173A),
    warning: Color(0xFFFFA000),
    onButtonFill: Color(0xFF121212),
    onErrorFill: Color(0xFFFFFFFF),
    highlightAccent: Color(0xFF7FD13B),
    tabActive: Color(0xFF2A3D22),
    misc: Color(0xFF6B1A24),
    lyricsCard: Color(0xFF5A1520),
    dividerToken: Color(0x14FFFFFF),
    scrollbarToken: Color(0xFF5A5A5A),
    headerGradientToken: Color(0x995A1520),
    layoutTokens: AppLayoutTokens.modern,
  );

  static const all = [
    green,
    red,
    verdantNight,
  ];
}

class AppThemeNotifier extends ValueNotifier<AppThemeData> {
  AppThemeNotifier._() : super(AppThemeData.green);
  static final instance = AppThemeNotifier._();
  static const _storageKey = 'desktop_theme';

  void toggle() => value =
      value == AppThemeData.green ? AppThemeData.red : AppThemeData.green;

  void setTheme(AppThemeData theme) {
    value = theme;
    _saveTheme(theme);
  }

  static Future<void> restoreSavedTheme() async {
    final box = Hive.box('settings');
    final name = box.get(_storageKey);
    if (name is! String) return;

    final saved = AppThemeData.all.cast<AppThemeData?>().firstWhere(
          (theme) => theme?.name == name,
          orElse: () => null,
        );
    if (saved != null) {
      instance.value = saved;
    }
  }

  static Future<void> _saveTheme(AppThemeData theme) async {
    await Hive.box('settings').put(_storageKey, theme.name);
  }
}

class AppThemeScope extends InheritedWidget {
  final AppThemeData theme;

  const AppThemeScope({super.key, required this.theme, required super.child});

  static AppThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.theme ??
      AppThemeData.green;

  static AppThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.theme;

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) => theme != oldWidget.theme;
}

class AppThemeBuilder extends StatefulWidget {
  final Widget Function(BuildContext, AppThemeData) builder;

  const AppThemeBuilder({super.key, required this.builder});

  @override
  State<AppThemeBuilder> createState() => _AppThemeBuilderState();
}

class _AppThemeBuilderState extends State<AppThemeBuilder> {
  @override
  void initState() {
    super.initState();
    AppThemeNotifier.instance.addListener(_changed);
  }

  @override
  void dispose() {
    AppThemeNotifier.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = AppThemeNotifier.instance.value;
    return AppThemeScope(
      theme: theme,
      child: widget.builder(context, theme),
    );
  }
}
