import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hidden developer mode, armed by tapping the drawer's Sign in row five
/// times and disarmed the same way.
///
/// It exists so the corridor can be tested without standing on it. Normally a
/// report is pinned to where the phone actually is, which is the right rule --
/// it is what stops someone filing hazards for a road they have never seen.
/// But it also means every test of the capture flow requires physically being
/// at a pothole, and there is no way to try a report at Kandholi while sitting
/// at Bidholi.
///
/// Deliberately invisible
/// ----------------------
/// No label, no switch in the settings, no banner, and the Sign in row looks
/// exactly as disabled as it did before. A visible developer toggle is one a
/// user finds, turns on, and then files reports from the wrong place with --
/// which would quietly poison the data the whole app depends on. The only
/// feedback is a haptic pulse on the fifth tap, which tells the person who
/// already knows the gesture that it worked, and tells nobody else anything.
///
/// Persisted so a restart mid-test does not silently drop back to normal
/// behaviour, which would look like the app ignoring a chosen location.
class AdminMode {
  AdminMode._();
  static final AdminMode instance = AdminMode._();

  static const String _key = 'roadscan.admin';

  /// Taps needed to toggle, and how long the run may take.
  static const int tapsToToggle = 5;
  static const Duration tapWindow = Duration(seconds: 3);

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  bool get isOn => enabled.value;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_key) ?? false;
    } catch (e) {
      // Never block startup over a debug affordance.
      debugPrint('RoadScan: admin flag unavailable: $e');
    }
  }

  Future<void> toggle() async {
    enabled.value = !enabled.value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled.value);
    } catch (e) {
      debugPrint('RoadScan: admin flag not saved: $e');
    }
  }
}
