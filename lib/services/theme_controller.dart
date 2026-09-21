import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the chosen theme and remembers it across launches.
///
/// A ValueNotifier rather than a state-management package: the app has exactly
/// one piece of global UI state, and adding Provider/Riverpod for it would be
/// more framework than the problem deserves. MaterialApp rebuilds on change
/// via a ValueListenableBuilder in main.dart.
///
/// Defaults to [ThemeMode.system] rather than forcing dark. The app is used
/// outdoors in daylight as often as at night, and the phone already knows
/// which the user prefers -- overriding that on first launch would be
/// presumptuous.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _key = 'roadscan.theme_mode';

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);

  /// Reads the saved preference. Failure is non-fatal: a missing or corrupt
  /// preference should start the app on the system theme, never block launch.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      mode.value = _fromWire(prefs.getString(_key));
    } catch (e) {
      debugPrint('RoadScan: could not read theme preference: $e');
    }
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.name);
    } catch (e) {
      // The theme still changed for this session; it just will not persist.
      debugPrint('RoadScan: could not save theme preference: $e');
    }
  }

  /// Cycles system -> light -> dark -> system, which is what a single
  /// tappable control in the drawer needs.
  Future<void> cycle() => set(switch (mode.value) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      });

  /// Whether dark colours are in effect right now, resolving
  /// [ThemeMode.system] against the platform. Widgets that need to pick an
  /// asset (the area cards pick a dark or light map thumbnail) need the
  /// resolved answer, not the mode.
  static bool isDark(BuildContext context, ThemeMode mode) => switch (mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          MediaQuery.platformBrightnessOf(context) == Brightness.dark,
      };

  static ThemeMode _fromWire(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String label(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Match device',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  static IconData icon(ThemeMode m) => switch (m) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };
}
