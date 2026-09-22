import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The three looks RoadScan ships.
///
/// Not Flutter's [ThemeMode]: that only knows light/dark/system, and `neon` is
/// a third distinct presentation rather than a brightness. It shares dark's
/// brightness but changes what the area cards draw (vector road networks that
/// glow, instead of raster map thumbnails) and how the map's road overlay is
/// coloured.
enum AppThemeKind {
  dark,
  light,
  neon;

  String get wire => name;

  /// Dark and neon are both dark-brightness; only `light` is not.
  bool get isDark => this != AppThemeKind.light;

  String get label => switch (this) {
        AppThemeKind.dark => 'Dark',
        AppThemeKind.light => 'Light',
        AppThemeKind.neon => 'Neon',
      };

  IconData get icon => switch (this) {
        AppThemeKind.dark => Icons.dark_mode_outlined,
        AppThemeKind.light => Icons.light_mode_outlined,
        AppThemeKind.neon => Icons.auto_awesome_outlined,
      };

  static AppThemeKind fromWire(String? s) => switch (s) {
        'light' => AppThemeKind.light,
        'neon' => AppThemeKind.neon,
        // Anything else -- 'dark', a stale 'system' from an older build, or a
        // corrupt value -- lands on dark, which is the default.
        _ => AppThemeKind.dark,
      };
}

/// Holds the chosen theme and remembers it across launches.
///
/// A ValueNotifier rather than a state-management package: the app has exactly
/// one piece of global UI state, and adding Provider/Riverpod for it would be
/// more framework than the problem deserves.
///
/// Starts on [AppThemeKind.dark] -- the app's own identity is dark, and it is
/// the look the map was designed against.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _key = 'roadscan.theme_mode';

  final ValueNotifier<AppThemeKind> kind =
      ValueNotifier(AppThemeKind.dark);

  AppThemeKind get value => kind.value;

  /// Reads the saved preference. Failure is non-fatal: a missing or corrupt
  /// preference should start the app on the default, never block launch.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      kind.value = AppThemeKind.fromWire(prefs.getString(_key));
    } catch (e) {
      debugPrint('RoadScan: could not read theme preference: $e');
    }
  }

  Future<void> set(AppThemeKind value) async {
    kind.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.wire);
    } catch (e) {
      // The theme still changed for this session; it just will not persist.
      debugPrint('RoadScan: could not save theme preference: $e');
    }
  }

  /// Dark <-> light. Neon is deliberately NOT in this rotation -- it has its
  /// own control, so switching day/night never lands you somewhere unexpected.
  Future<void> toggleBrightness() => set(
        value == AppThemeKind.light ? AppThemeKind.dark : AppThemeKind.light,
      );

  /// Turns neon on, or back to dark if it is already on.
  Future<void> toggleNeon() => set(
        value == AppThemeKind.neon ? AppThemeKind.dark : AppThemeKind.neon,
      );

  bool get isNeon => value == AppThemeKind.neon;
}
