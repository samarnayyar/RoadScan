import 'package:maplibre_gl/maplibre_gl.dart';

/// Every tunable number in RoadScan lives here, so the viva-day question
/// "why 20 metres?" has one place to point at.
class AppConfig {
  AppConfig._();

  // --------------------------------------------------------------------------
  // Supabase
  //
  // Supplied at build time so keys never land in git:
  //   flutter run --dart-define-from-file=supabase.json
  //
  // The client key is safe to ship in a binary -- it only grants what the RLS
  // policies in supabase/schema.sql allow. The service_role / secret key is
  // NOT, and must never appear in this app.
  // --------------------------------------------------------------------------
  static const String supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');

  // Supabase renamed this key. New projects show a "Publishable key"
  // (sb_publishable_...); older ones show "anon public" (eyJ...). Both are the
  // same thing to the client and go in the same slot, so accept either name
  // rather than making the right one depend on when the project was created.
  static const String _publishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: '');
  static const String _anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  static String get supabaseKey =>
      _publishableKey.isNotEmpty ? _publishableKey : _anonKey;

  static bool get hasSupabaseCredentials =>
      supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  static const String photoBucket = 'hazard-photos';

  // --------------------------------------------------------------------------
  // Map
  // --------------------------------------------------------------------------

  /// OpenFreeMap's public instance: no API key, no registration, and no cap on
  /// map views or tile requests. That last part is why it beats MapTiler's free
  /// tier here -- a quota that can be exhausted is a demo that can fail.
  ///
  /// `liberty` carries building height attributes in the OpenMapTiles schema,
  /// which is what the 3D extrusion layer reads.
  static const String mapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

  /// UPES Energy Acres. Ground-truthed by hand against a Google Maps pin
  /// dropped on campus (30.415671, 77.966007) -- the OSM-geocoded value used
  /// before this was ~306m off, into a neighbouring industrial plot rather
  /// than the campus itself.
  static const LatLng campusCenter = LatLng(30.415671, 77.966007);

  /// The areas offered on the launch screen.
  ///
  /// Coordinates below marked GROUND-TRUTHED were hand-verified against
  /// Google Maps pins dropped on the actual place (not geocoded against an
  /// address string). The previous OSM-geocoded values were all off by
  /// 300m-1.2km -- Nanda Ki Chowki in particular resolved to a point over a
  /// kilometre from the real junction. See PROJECT_LOG.txt 6.12 for the first
  /// round of this bug and 8.2 for why Kandholi was missing entirely.
  ///
  /// "Kandholi" here is UPES's second Dehradun campus, Knowledge Acres --
  /// not a village of that name, which is why it never turned up in an OSM
  /// search. Bidholi (the village) and Kandholi (the campus) are ~770m
  /// apart, genuinely different places, so this replaces the earlier
  /// generic "Bidholi village" slot rather than merely correcting it.
  static const List<CampusArea> areas = [
    CampusArea(
      id: 'upes-bidholi',
      name: 'UPES Bidholi',
      subtitle: 'Energy Acres campus',
      center: LatLng(30.415671, 77.966007), // GROUND-TRUTHED
      zoom: 16.0,
    ),
    CampusArea(
      id: 'kandholi',
      name: 'Kandholi',
      subtitle: 'UPES Knowledge Acres campus',
      center: LatLng(30.383750, 77.969657), // GROUND-TRUTHED
      zoom: 16.0,
    ),
    CampusArea(
      id: 'pondha',
      name: 'Pondha',
      subtitle: 'Kaulagarh Road',
      center: LatLng(30.375002, 77.977719), // GROUND-TRUTHED
      zoom: 15.5,
    ),
    CampusArea(
      id: 'nanda-ki-chowki',
      name: 'Nanda Ki Chowki',
      subtitle: 'Chakrata Road junction',
      center: LatLng(30.343468, 77.953149), // GROUND-TRUTHED
      zoom: 15.5,
    ),
  ];

  static CampusArea areaById(String id) =>
      areas.firstWhere((a) => a.id == id, orElse: () => areas.first);

  /// Camera bounds covering the whole corridor.
  ///
  /// The corridor actually runs Nanda Ki Chowki (30.343) in the south up to
  /// UPES (30.418) in the north -- roughly 8 km. The previous box started at
  /// 30.395, which silently excluded everything south of the campus and made
  /// three of the four areas unreachable. Margin added on each side so the
  /// user can pan a little past each end.
  static final LatLngBounds campusBounds = LatLngBounds(
    southwest: const LatLng(30.325, 77.915),
    northeast: const LatLng(30.440, 78.000),
  );

  static const double initialZoom = 15.5;
  static const double minZoom = 12.0;
  static const double maxZoom = 19.0;

  /// Default camera tilt. 45 degrees reads as clearly 3D without the horizon
  /// eating half the screen the way 60 does.
  static const double initialPitch = 45.0;
  static const double maxPitch = 60.0;

  // --------------------------------------------------------------------------
  // Detection
  // --------------------------------------------------------------------------

  /// Bundled LiteRT export. See ml/train_export.py.
  static const String modelAsset = 'assets/models/roadscan.tflite';

  /// Fallback when no fine-tuned model has been bundled yet. The plugin
  /// downloads this on first run so the app is demoable before training
  /// finishes -- it will NOT detect potholes, it just keeps the pipeline alive.
  static const String fallbackModelId = 'yolo26n';

  /// Below this, a detection is noise. Tuned on the assumption of a fine-tuned
  /// 2-class model; re-check after training on real Bidholi photos.
  static const double minConfidence = 0.35;

  // --------------------------------------------------------------------------
  // Dedup / confidence
  // --------------------------------------------------------------------------

  /// Radius for "this is the same pothole I already reported". Consumer phone
  /// GPS is typically 5-10m accurate, so anything under ~15m would split one
  /// pothole into several pins on GPS jitter alone. 20m is the top of the
  /// brief's range, chosen for that reason.
  static const double dedupRadiusMeters = 20.0;

  /// Decay constant: confidence = base * e^(-lambda * days).
  /// At lambda = 0.05, a pin reads ~0.61 after 10 days and ~0.22 after 30.
  static const double decayLambda = 0.05;

  /// Days without re-confirmation before a pin renders as stale.
  static const int staleAfterDays = 30;

  /// Distinct devices that must report "no hazard here" to flip a pin to fixed.
  static const int fixedThreshold = 3;

  /// A pin newer than this pulses on the map.
  static const Duration freshWindow = Duration(hours: 24);

  // --------------------------------------------------------------------------
  // Proximity alerts
  // --------------------------------------------------------------------------

  /// How close a high/critical pin must be before it fires an alert. At 40km/h
  /// this is roughly 18 seconds of warning -- enough to react, short enough not
  /// to fire constantly on a dense campus road.
  static const double alertRadiusMeters = 200.0;

  /// Don't re-alert for the same pin inside this window.
  static const Duration alertCooldown = Duration(minutes: 10);

  /// How far around the user to cache pins for offline proximity checks.
  static const double pinFetchRadiusMeters = 3000.0;
}

/// One selectable area on the launch screen.
class CampusArea {
  const CampusArea({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.center,
    required this.zoom,
  });

  final String id;
  final String name;
  final String subtitle;
  final LatLng center;
  final double zoom;
}
