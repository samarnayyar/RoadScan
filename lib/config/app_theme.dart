import 'package:flutter/material.dart';

import '../services/theme_controller.dart' show AppThemeKind;

/// RoadScan's semantic colours.
///
/// The app uses far more colours than Material's ColorScheme names sensibly
/// (card gradients, hairline borders, three tiers of muted text), and before
/// this they were hardcoded hex literals scattered across every screen -- which
/// is precisely why light mode was a refactor rather than a switch. Everything
/// theme-dependent now resolves through here, so a new palette is one object,
/// not a grep.
///
/// Note what is NOT in here: the severity colours (green/amber/orange/red in
/// hazard_report.dart) and the hazard orange. Those encode meaning rather than
/// style -- a critical pothole must look critical in both themes -- so they
/// stay fixed deliberately.
@immutable
class RoadScanColors extends ThemeExtension<RoadScanColors> {
  const RoadScanColors({
    required this.background,
    required this.backgroundDeep,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.scrim,
    required this.chromeBorder,
    required this.isDark,
    required this.kind,
  });

  /// Page background.
  final Color background;

  /// The darker end of the background gradient.
  final Color backgroundDeep;

  /// Cards, sheets, bars.
  final Color surface;

  /// A second surface tone for nested elements.
  final Color surfaceAlt;

  final Color border;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  final Color accent;

  /// Accent at low emphasis, for fills behind accent-coloured content.
  final Color accentSoft;

  /// Overlay used to keep text legible over imagery.
  final Color scrim;

  /// Outline for floating chrome sitting ON the map -- the action bar, the
  /// round map buttons, the pitch control.
  ///
  /// Deliberately not [border]. Those controls are frosted glass over live map
  /// content, so their outline has to contrast with the MAP, not with a panel
  /// behind them. It therefore inverts: dark in light mode, light in dark
  /// mode. Using a white hairline in both (as this did) left the controls with
  /// no visible edge at all against a pale basemap.
  final Color chromeBorder;

  /// Lets widgets branch on brightness without reaching for Theme.of again.
  final bool isDark;

  /// Which of the three looks is active.
  ///
  /// Needed beyond [isDark] because neon and dark share a brightness but
  /// render the area cards completely differently -- neon draws vector road
  /// networks that glow, the other two show raster map thumbnails.
  final AppThemeKind kind;

  bool get isNeon => kind == AppThemeKind.neon;

  static const RoadScanColors dark = RoadScanColors(
    // Near-neutral charcoal with only a trace of blue. The previous values
    // were a saturated navy, which is what made the launch screen read as a
    // blue gradient wallpaper rather than as an instrument panel.
    background: Color(0xFF14171A),
    backgroundDeep: Color(0xFF0B0D0F),
    surface: Color(0xFF1E2327),
    surfaceAlt: Color(0xFF191D21),
    border: Color(0xFF2E353B),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF9AA5AD),
    textMuted: Color(0xFF6B757D),
    accent: Color(0xFF2E9CD6),
    accentSoft: Color(0x332E9CD6),
    scrim: Color(0xD8091521),
    // Fully opaque white. A translucent hairline picked up whatever was under
    // it and read as muddy rather than as a defined edge.
    chromeBorder: Color(0xFFFFFFFF),
    isDark: true,
    kind: AppThemeKind.dark,
  );

  /// Neon: dark's structure, pushed further.
  ///
  /// Blacker ground and a brighter, more saturated accent, because everything
  /// this theme draws is meant to look self-lit against it. Sharing dark's
  /// layout values keeps the switch a repaint rather than a relayout.
  static const RoadScanColors neon = RoadScanColors(
    // True OLED black. On this phone's panel a #000 pixel is physically off,
    // so the glow has nothing behind it to wash against and the colour reads
    // at full strength -- which is the entire point of this theme. It also
    // costs less battery than the near-blacks the other themes use.
    background: Color(0xFF000000),
    backgroundDeep: Color(0xFF000000),
    // Surfaces stay very dark too, so panels do not appear as grey rectangles
    // floating on a black field.
    surface: Color(0xFF0A0D11),
    surfaceAlt: Color(0xFF05070A),
    border: Color(0xFF1D2630),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF9FB4C4),
    textMuted: Color(0xFF6A8090),
    accent: Color(0xFF3FE0FF),
    accentSoft: Color(0x333FE0FF),
    scrim: Color(0xE0040608),
    chromeBorder: Color(0xFF3FE0FF),
    isDark: true,
    kind: AppThemeKind.neon,
  );

  static const RoadScanColors light = RoadScanColors(
    // Not pure white: this app is used outdoors on a phone held at arm's
    // length, and a blank white field is harsh in sunlight and glare-prone.
    // A faint blue-grey keeps the same family as the dark theme.
    background: Color(0xFFEEF2F6),
    backgroundDeep: Color(0xFFDDE5EC),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFE6EDF3),
    border: Color(0xFFCBD7E1),
    textPrimary: Color(0xFF0E1A26),
    textSecondary: Color(0xFF52687C),
    textMuted: Color(0xFF7F93A5),
    accent: Color(0xFF1B6CA8),
    accentSoft: Color(0x261B6CA8),
    scrim: Color(0xCCFFFFFF),
    // Fully opaque black, mirroring the white used in dark mode. A softer
    // near-navy at partial alpha was tried first and read as indistinct
    // against the basemap -- the controls need a hard edge, not a tint.
    chromeBorder: Color(0xFF000000),
    isDark: false,
    kind: AppThemeKind.light,
  );

  @override
  RoadScanColors copyWith({
    Color? background,
    Color? backgroundDeep,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? accentSoft,
    Color? scrim,
    Color? chromeBorder,
    bool? isDark,
    AppThemeKind? kind,
  }) {
    return RoadScanColors(
      background: background ?? this.background,
      backgroundDeep: backgroundDeep ?? this.backgroundDeep,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      scrim: scrim ?? this.scrim,
      chromeBorder: chromeBorder ?? this.chromeBorder,
      isDark: isDark ?? this.isDark,
      kind: kind ?? this.kind,
    );
  }

  @override
  RoadScanColors lerp(ThemeExtension<RoadScanColors>? other, double t) {
    if (other is! RoadScanColors) return this;
    return RoadScanColors(
      background: Color.lerp(background, other.background, t)!,
      backgroundDeep: Color.lerp(backgroundDeep, other.backgroundDeep, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      chromeBorder: Color.lerp(chromeBorder, other.chromeBorder, t)!,
      // A half-faded theme still has to answer these; snap at the midpoint
      // rather than pretending they are meaningfully interpolable.
      isDark: t < 0.5 ? isDark : other.isDark,
      kind: t < 0.5 ? kind : other.kind,
    );
  }
}

/// Convenience accessor: `context.rs.accent` instead of
/// `Theme.of(context).extension<RoadScanColors>()!.accent`.
extension RoadScanThemeAccess on BuildContext {
  RoadScanColors get rs =>
      Theme.of(this).extension<RoadScanColors>() ?? RoadScanColors.dark;
}

class AppTheme {
  AppTheme._();

  /// Map style per theme, both from the same keyless, uncapped OpenFreeMap
  /// instance the project already committed to.
  ///
  /// Verified rather than assumed: `liberty`, `fiord` and `dark` all expose a
  /// source named `openmaptiles` pointing at the SAME vector tiles
  /// (tiles.openfreemap.org/planet). That matters because RoadScan adds its
  /// own fill-extrusion layer against that source name and reads
  /// `render_height` off the `building` source-layer -- an attribute of the
  /// tile DATA, not of the style. So the 3D buildings survive the theme
  /// switch even though only `liberty`'s own layers happen to reference
  /// render_height.
  ///
  /// `dark` (near-black, rgb(12,12,12)) rather than `fiord` (slate #45516E).
  ///
  /// Both were tried on device. Black looks considerably better against the
  /// app's chrome, which is why it won. Its one real weakness is that the
  /// style's own road casings are barely lighter than its background, so on a
  /// rural stretch like Kandholi the road network all but disappears -- fatal
  /// for a road-hazard map. That is fixed by MapLayers.addRoadContrast(),
  /// which draws the road network back on top in dark mode, rather than by
  /// settling for a washed-out basemap.
  static const String mapStyleLight =
      'https://tiles.openfreemap.org/styles/liberty';
  static const String mapStyleDark =
      'https://tiles.openfreemap.org/styles/dark';

  static ThemeData build(RoadScanColors c) {
    final scheme = ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: c.isDark ? Brightness.dark : Brightness.light,
    ).copyWith(
      surface: c.surface,
      onSurface: c.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: c.isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.surface,
      dividerColor: c.border,
      extensions: [c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
      ),
      drawerTheme: DrawerThemeData(backgroundColor: c.surface),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.isDark ? c.surfaceAlt : const Color(0xFF22394D),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }

  static ThemeData get dark => build(RoadScanColors.dark);
  static ThemeData get light => build(RoadScanColors.light);
  static ThemeData get neon => build(RoadScanColors.neon);

  static RoadScanColors colorsFor(AppThemeKind kind) => switch (kind) {
        AppThemeKind.dark => RoadScanColors.dark,
        AppThemeKind.light => RoadScanColors.light,
        AppThemeKind.neon => RoadScanColors.neon,
      };

  static ThemeData themeFor(AppThemeKind kind) => build(colorsFor(kind));

  /// Basemap style per theme. Neon rides on the same near-black basemap as
  /// dark; what makes it neon is the road overlay drawn on top of it (see
  /// MapLayers.addRoadContrast).
  static String mapStyleFor(AppThemeKind kind) =>
      kind == AppThemeKind.light ? mapStyleLight : mapStyleDark;
}
