import 'package:flutter/material.dart';

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
    required this.isDark,
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

  /// Lets widgets branch on brightness without reaching for Theme.of again.
  final bool isDark;

  static const RoadScanColors dark = RoadScanColors(
    background: Color(0xFF0E1A26),
    backgroundDeep: Color(0xFF070F18),
    surface: Color(0xFF16293A),
    surfaceAlt: Color(0xFF12222F),
    border: Color(0xFF22394D),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF8FA3B5),
    textMuted: Color(0xFF5E7386),
    accent: Color(0xFF2E9CD6),
    accentSoft: Color(0x332E9CD6),
    scrim: Color(0xD8091521),
    isDark: true,
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
    isDark: false,
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
    bool? isDark,
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
      isDark: isDark ?? this.isDark,
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
      // A half-faded theme still has to answer this; snap at the midpoint
      // rather than pretending it is meaningfully interpolable.
      isDark: t < 0.5 ? isDark : other.isDark,
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
}
