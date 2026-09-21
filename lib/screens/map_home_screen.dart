import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../config/map_layers.dart';
import '../services/theme_controller.dart';
import '../models/hazard_report.dart';
import '../services/location_service.dart';
import '../services/proximity_alerts.dart';
import '../services/supabase_service.dart';
import 'package:image_picker/image_picker.dart';

import '../services/device_identity.dart';
import '../widgets/app_drawer.dart';
import '../widgets/glass_action_bar.dart';
import '../widgets/hazard_alert_banner.dart';
import '../widgets/pin_detail_sheet.dart';
import '../widgets/pitch_control.dart';
import '../widgets/stats_overlay.dart';
import 'capture_screen.dart' show CaptureScreen, CaptureResult;

class MapHomeScreen extends StatefulWidget {
  const MapHomeScreen({super.key, this.area});

  /// Chosen on the launch screen. Null falls back to the default campus centre.
  final CampusArea? area;

  @override
  State<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends State<MapHomeScreen> {
  MapLibreMapController? _controller;
  StreamSubscription<Position>? _positionSub;

  List<HazardReport> _reports = const [];
  bool _styleReady = false;
  bool _loadingPins = false;

  /// Set once we have deliberately positioned the camera.
  ///
  /// Until then onCameraIdle must not write back to _pitch/_bearing: MapLibre
  /// Android does not reliably honour `tilt` from initialCameraPosition, so it
  /// reports 0 during startup, and syncing that would silently flatten the map
  /// and leave the pitch slider pinned at zero.
  bool _cameraReady = false;
  String? _error;

  double _pitch = AppConfig.initialPitch;
  double _bearing = 0;

  /// The hazard currently being warned about, and how far away it is.
  HazardReport? _alertReport;
  double _alertDistance = 0;
  final Set<String> _dismissedAlerts = {};

  CampusArea get _area => widget.area ?? AppConfig.areas.first;

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _deviceId = '';

  /// The map widget, built once and reused.
  ///
  /// MapLibreMap hosts a native platform view. Rebuilding its widget on every
  /// setState -- and setState fires on each GPS tick, camera settle and pin
  /// refresh -- makes Flutter re-diff the platform view on frames where
  /// nothing about the map changed. Caching it means state changes only
  /// rebuild the lightweight overlays on top.
  Widget? _mapWidget;

  /// The basemap style the cached [_mapWidget] was built with.
  ///
  /// MapLibreMap takes its style at construction, so a theme change has to
  /// drop the cache and rebuild the platform view. That resets the camera to
  /// the area centre, which is a visible jump -- acceptable because switching
  /// theme is rare and deliberate, and the user is expecting the map to change
  /// appearance anyway.
  String? _builtStyle;

  @override
  void initState() {
    super.initState();
    DeviceIdentity.instance.id.then((id) {
      if (mounted) setState(() => _deviceId = id);
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Map lifecycle
  // ---------------------------------------------------------------------------

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
  }

  /// Layers must be added after the style loads -- adding them against a
  /// half-initialised style silently no-ops, which looks exactly like a
  /// rendering bug and is a classic way to lose an afternoon.
  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;

    // Dark basemap only: `liberty` already draws roads with plenty of
    // contrast, but OpenFreeMap's `dark` style makes them nearly invisible.
    // See MapLayers.addRoadContrast.
    if (_builtStyle == AppTheme.mapStyleDark) {
      try {
        await MapLayers.addRoadContrast(c);
      } catch (e) {
        debugPrint('RoadScan: road contrast layer unavailable: $e');
      }
    }

    try {
      await MapLayers.addBuildings(c);
    } catch (e) {
      // A tile source without building heights shouldn't take the map down;
      // the app is still fully usable in 2D.
      debugPrint('RoadScan: 3D buildings unavailable: $e');
    }

    await c.addGeoJsonSource(
      MapLayers.pinSourceId,
      MapLayers.pinsGeoJson(const []),
    );
    await MapLayers.addPinLayers(c);

    if (!mounted) return;
    setState(() => _styleReady = true);

    // Apply the tilt explicitly rather than trusting initialCameraPosition.
    // This is what actually makes the map read as 3D.
    await c.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _area.center,
          zoom: _area.zoom,
          tilt: AppConfig.initialPitch,
          bearing: 0,
        ),
      ),
      duration: const Duration(milliseconds: 600),
    );
    if (!mounted) return;
    setState(() {
      _pitch = AppConfig.initialPitch;
      _cameraReady = true;
    });

    await _startLocation();
    await _refreshPins();
  }

  Future<void> _startLocation() async {
    try {
      final pos = await LocationService.instance.currentPosition();
      await _flyTo(LatLng(pos.latitude, pos.longitude));

      _positionSub?.cancel();
      _positionSub = LocationService.instance.watch().listen((p) {
        // Proximity alerting rides on the same position stream that drives the
        // map dot -- one GPS subscription, not two.
        ProximityAlerts.instance.onPosition(p, _reports);
        _updateLiveAlert(p);
      });
    } on LocationUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      // Without a fix we still show the area, just not the user.
      await _flyTo(_area.center);
    }
  }

  Future<void> _flyTo(LatLng target) async {
    await _controller?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: target,
          zoom: _area.zoom,
          tilt: _pitch,
          bearing: _bearing,
        ),
      ),
      duration: const Duration(milliseconds: 900),
    );
  }

  // ---------------------------------------------------------------------------
  // Pins
  // ---------------------------------------------------------------------------

  Future<void> _refreshPins() async {
    if (!SupabaseService.instance.isConfigured) {
      setState(() => _error =
          'Supabase is not configured. Pass --dart-define=SUPABASE_URL and '
          'SUPABASE_ANON_KEY to see live pins.');
      return;
    }
    if (_loadingPins) return;
    setState(() => _loadingPins = true);

    try {
      final origin = LocationService.instance.lastKnown;
      final reports = await SupabaseService.instance.nearby(
        lat: origin?.latitude ?? _area.center.latitude,
        lon: origin?.longitude ?? _area.center.longitude,
      );

      if (!mounted) return;
      setState(() {
        _reports = reports;
        _error = null;
      });
      await _controller?.setGeoJsonSource(
        MapLayers.pinSourceId,
        MapLayers.pinsGeoJson(reports),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load pins: $e');
    } finally {
      if (mounted) setState(() => _loadingPins = false);
    }
  }

  /// Hit-tests the pin layer at the tap point.
  ///
  /// Querying rendered features (rather than comparing tap lat/lng to pin
  /// coordinates ourselves) is what makes tapping work correctly when the map
  /// is pitched -- screen distance and ground distance stop being proportional
  /// the moment the camera tilts.
  Future<void> _onMapClick(math.Point<double> point, LatLng coords) async {
    final c = _controller;
    if (c == null || _reports.isEmpty) return;

    // A finger is far wider than a pixel; query a small box around the tap.
    const pad = 22.0;
    List<dynamic> features;
    try {
      features = await c.queryRenderedFeatures(
        point,
        [MapLayers.pinCoreLayerId],
        null,
      );
    } catch (e) {
      debugPrint('RoadScan: feature query failed: $e');
      return;
    }

    String? id = _idFromFeatures(features);

    // Fall back to nearest-pin-within-a-finger-width if the exact hit missed.
    id ??= _nearestPinId(coords, maxMeters: pad * _metresPerPixel(coords));

    if (id == null) return;
    HazardReport? report;
    for (final r in _reports) {
      if (r.id == id) {
        report = r;
        break;
      }
    }
    if (report == null || !mounted) return;

    await showPinDetailSheet(
      context,
      report: report,
      onChanged: _refreshPins,
    );
  }

  String? _idFromFeatures(List<dynamic> features) {
    for (final f in features) {
      if (f is Map) {
        final props = f['properties'];
        if (props is Map && props['id'] is String) return props['id'] as String;
        if (f['id'] is String) return f['id'] as String;
      }
    }
    return null;
  }

  String? _nearestPinId(LatLng tap, {required double maxMeters}) {
    String? best;
    double bestD = double.infinity;
    for (final r in _reports) {
      final d = LocationService.distanceMeters(
          tap.latitude, tap.longitude, r.lat, r.lon);
      if (d < bestD) {
        bestD = d;
        best = r.id;
      }
    }
    return bestD <= maxMeters ? best : null;
  }

  /// Ground resolution of one screen pixel at the current zoom and latitude.
  double _metresPerPixel(LatLng at) {
    final zoom = _controller?.cameraPosition?.zoom ?? AppConfig.initialZoom;
    return 156543.03392 *
        math.cos(at.latitude * math.pi / 180) /
        math.pow(2, zoom + 8);
  }


  // ---------------------------------------------------------------------------
  // Live proximity banner
  // ---------------------------------------------------------------------------

  /// Recomputes which hazard the banner should be warning about.
  ///
  /// Runs on every GPS tick. Separate from ProximityAlerts, which fires the
  /// one-shot system notification and has a cooldown: this banner has no
  /// cooldown because it must track the distance down continuously as the
  /// rider approaches, then disappear once the hazard is passed.
  void _updateLiveAlert(Position p) {
    HazardReport? nearest;
    double nearestDistance = double.infinity;

    for (final r in _reports) {
      if (!r.shouldAlert) continue;
      if (_dismissedAlerts.contains(r.id)) continue;

      final d = LocationService.distanceMeters(
          p.latitude, p.longitude, r.lat, r.lon);
      if (d <= AppConfig.alertRadiusMeters && d < nearestDistance) {
        nearestDistance = d;
        nearest = r;
      }
    }

    // Only rebuild when something actually changed. A GPS tick arrives every
    // few metres, and calling setState on each one would rebuild the map stack
    // needlessly.
    final changedPin = nearest?.id != _alertReport?.id;
    final changedDistance = (nearestDistance - _alertDistance).abs() > 5;
    if (!changedPin && !changedDistance) return;

    setState(() {
      _alertReport = nearest;
      _alertDistance = nearestDistance;
    });
  }

  void _dismissAlert() {
    final id = _alertReport?.id;
    if (id == null) return;
    setState(() {
      // Dismissal is per-pin and lasts for this screen only, so walking away
      // and coming back still warns you.
      _dismissedAlerts.add(id);
      _alertReport = null;
    });
  }

  Future<void> _switchArea() async {
    // Popping back to the launch screen keeps one source of truth for the area
    // rather than duplicating the picker inside the map.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------------------------
  // Camera controls
  // ---------------------------------------------------------------------------

  void _setPitch(double value) {
    setState(() => _pitch = value);
    _controller?.animateCamera(
      CameraUpdate.tiltTo(value),
      duration: const Duration(milliseconds: 180),
    );
  }

  void _resetBearing() {
    setState(() => _bearing = 0);
    _controller?.animateCamera(
      CameraUpdate.bearingTo(0),
      duration: const Duration(milliseconds: 350),
    );
  }

  Future<void> _openCapture(ImageSource source) async {
    final result = await Navigator.of(context).push<CaptureResult>(
      MaterialPageRoute(builder: (_) => CaptureScreen(source: source)),
    );
    if (!mounted) return;

    // Anything other than a successful submit -- backing out of the picker,
    // hardware back from the review screen, a cancelled retake -- lands here
    // with null or a non-submitted result. Say so explicitly: a silent return
    // to the map looks identical to a crash or a failed upload.
    if (result == CaptureResult.submitted) {
      await _refreshPins();
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('No image uploaded.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }


  /// Constructed once per basemap style; see [_mapWidget] and [_builtStyle].
  Widget _buildMap(String styleUrl) {
    if (_mapWidget != null && _builtStyle == styleUrl) return _mapWidget!;

    // Style changed (theme switch): the layers we add in _onStyleLoaded belong
    // to the old style object, so reset the readiness flags and let the new
    // style's load callback re-add them.
    _builtStyle = styleUrl;
    _styleReady = false;
    _cameraReady = false;

    return _mapWidget = RepaintBoundary(
      key: ValueKey(styleUrl),
      child:
          MapLibreMap(
            styleString: styleUrl,
            initialCameraPosition: CameraPosition(
              target: _area.center,
              zoom: _area.zoom,
              tilt: AppConfig.initialPitch,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _onMapClick,
            // Keeps the demo inside Bidholi-Kandholi-Pondha: panning to Delhi
            // would show an empty map and read as a broken app.
            cameraTargetBounds: CameraTargetBounds(AppConfig.campusBounds),
            minMaxZoomPreference: const MinMaxZoomPreference(
              AppConfig.minZoom,
              AppConfig.maxZoom,
            ),
            myLocationEnabled: true,
            myLocationTrackingMode: MyLocationTrackingMode.tracking,
            myLocationRenderMode: MyLocationRenderMode.compass,
            tiltGesturesEnabled: true,
            rotateGesturesEnabled: true,
            compassEnabled: true,
            trackCameraPosition: true,
            onCameraIdle: () {
              // Ignore idle events fired before we positioned the camera.
              if (!_cameraReady) return;
              final cam = _controller?.cameraPosition;
              if (cam == null || !mounted) return;
              if ((cam.bearing - _bearing).abs() > 0.5 ||
                  (cam.tilt - _pitch).abs() > 0.5) {
                setState(() {
                  _bearing = cam.bearing;
                  _pitch = cam.tilt;
                });
              }
            },
          )
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.rs;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        final dark = ThemeController.isDark(context, mode);
        final styleUrl =
            dark ? AppTheme.mapStyleDark : AppTheme.mapStyleLight;
        return _buildScaffold(context, c, styleUrl);
      },
    );
  }

  Widget _buildScaffold(
      BuildContext context, RoadScanColors c, String styleUrl) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: AppDrawer(deviceId: _deviceId.isEmpty ? '00000000' : _deviceId),
      body: Stack(
        children: [
          _buildMap(styleUrl),

          if (!_styleReady)
            ColoredBox(
              color: c.background,
              child: const Center(child: CircularProgressIndicator()),
            ),

          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 10),
                      child: Material(
                        color: c.surface.withValues(alpha: 0.94),
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: Icon(Icons.menu, size: 22, color: c.textPrimary),
                          tooltip: 'Menu',
                          onPressed: () =>
                              _scaffoldKey.currentState?.openDrawer(),
                        ),
                      ),
                    ),
                    Expanded(
                      child: StatsOverlay(
                        reports: _reports,
                        loading: _loadingPins,
                        onRefresh: _refreshPins,
                        areaName: _area.name,
                        onSwitchArea: _switchArea,
                      ),
                    ),
                  ],
                ),
                if (_error != null) _ErrorBanner(message: _error!),

                // The proximity warning. Sits directly under the header, on the
                // left, so it is the first thing in the reading path and never
                // covers the Scan button.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 40, 0),
                  child: AnimatedAlertSlot(
                    child: _alertReport == null
                        ? null
                        : HazardAlertBanner(
                            key: ValueKey(_alertReport!.id),
                            report: _alertReport!,
                            distanceMeters: _alertDistance,
                            thumbnailUrl: _alertReport!.latestPhotoPath == null
                                ? null
                                : SupabaseService.instance.publicUrl(
                                    _alertReport!.latestPhotoPath!),
                            onDismiss: _dismissAlert,
                            onTap: () => showPinDetailSheet(
                              context,
                              report: _alertReport!,
                              onChanged: _refreshPins,
                            ),
                          ),
                  ),
                ),

                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      PitchControl(
                        pitch: _pitch,
                        bearing: _bearing,
                        onPitchChanged: _setPitch,
                        onResetBearing: _resetBearing,
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                GlassActionBar(
                  onCamera: () => _openCapture(ImageSource.camera),
                  onGallery: () => _openCapture(ImageSource.gallery),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF0C48A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: Color(0xFF9A6216)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A4E12)),
            ),
          ),
        ],
      ),
    );
  }
}
