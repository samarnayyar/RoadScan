import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/app_theme.dart';
import 'screens/area_select_screen.dart';
import 'services/admin_mode.dart';
import 'services/proximity_alerts.dart';
import 'services/supabase_service.dart';
import 'services/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait only.
  //
  // Every screen here is a single vertical column -- the map with its pitch
  // slider and action bar, the capture review, the report sheet -- and in
  // landscape there is simply not enough height for them: the map screen
  // overflows its own layout by about 80px on this phone. Landscape would
  // need a genuinely different layout for each screen, and it is not a
  // posture anyone holds a phone in while checking the road ahead. Locking
  // it is the honest fix rather than squeezing a column that does not fit.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Before runApp so the first frame is already in the right theme -- loading
  // it afterwards would flash the wrong palette on every cold start.
  await ThemeController.instance.load();

  // Hidden developer flag; see AdminMode. Loaded here so the capture flow
  // does not have to await it mid-gesture.
  await AdminMode.instance.load();

  // Neither of these is allowed to prevent the app from starting. A missing
  // Supabase key or a denied notification permission should degrade the app to
  // "3D map with no pins", not to a blank screen -- which matters when the
  // demo device is on unfamiliar campus wifi.
  try {
    await SupabaseService.initialise();
  } catch (e) {
    debugPrint('RoadScan: Supabase init failed: $e');
  }

  try {
    await ProximityAlerts.instance.initialise();
  } catch (e) {
    debugPrint('RoadScan: notifications unavailable: $e');
  }

  runApp(const RoadScanApp());
}

class RoadScanApp extends StatelessWidget {
  const RoadScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeKind>(
      valueListenable: ThemeController.instance.kind,
      builder: (context, kind, _) {
        // One explicit theme rather than light/dark/themeMode: `neon` is a
        // third look, not a brightness, so MaterialApp's two-slot scheme
        // cannot express it.
        return MaterialApp(
          title: 'RoadScan',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(kind),
          home: const AreaSelectScreen(),
        );
      },
    );
  }
}
