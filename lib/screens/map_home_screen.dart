import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../config/map_layers.dart';
import '../services/theme_controller.dart';
import '../models/hazard_report.dart';
import '../services/location_service.dart';
import '../services/map_style.dart';
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

class _MapHomeScreenState extends State<MapHomeScreen>
    with WidgetsBindingObserver {
  MapLibreMapController? _controller;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<ServiceStatus>? _serviceSub;

  /// True once the position stream is live. Guards the retry paths so
  /// enabling location twice does not open two GPS subscriptions.
  bool _locationActive = false;

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

  /// The basemap style currently applied to the live map.
  ///
  /// Theme changes go through `controller.setStyle()`, which swaps the style
  /// on the EXISTING native view. The obvious alternative -- rebuilding the
  /// MapLibreMap widget with a new `styleString` -- is what this used to do,
  /// and it was slow and visibly janky: it tears down the native surface,
  /// constructs a fresh one, refetches style, glyphs and sprites, re-adds
  /// every layer and then has to restore the camera by hand. setStyle keeps
  /// the surface and the camera, so only the style itself is refetched.
  String? _builtStyle;

  /// The theme the live layers were built for.
  ///
  /// Tracked separately from [_builtStyle] because dark and neon share the
  /// same basemap URL -- what differs is the road overlay drawn on top. Keying
  /// the swap on the style alone meant switching dark <-> neon changed
  /// nothing on the map at all.
  AppThemeKind? _builtKind;

  /// Guards against firing setStyle repeatedly while one is already in flight
  /// (build can run several times before the new style finishes loading).
  bool _styleSwapInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceIdentity.instance.id.then((id) {
      if (mounted) setState(() => _deviceId = id);
    });

    // Watch for the user flipping location on in system settings. This is the
    // direct fix for "I turned GPS on and the map never noticed": the startup
    // fix has already failed and been given up on by then, so something has to
    // ask again.
    _serviceSub = LocationService.instance.serviceStatus().listen((status) {
      if (status == ServiceStatus.enabled) _retryLocation();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Covers the other half of the same problem: granting the PERMISSION
    // (rather than switching the service on) happens in a system dialog or in
    // Settings, and produces no ServiceStatus event at all. Coming back to the
    // app is the reliable signal that something may have changed.
    if (state == AppLifecycleState.resumed) _retryLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _serviceSub?.cancel();
    super.dispose();
  }

  /// Starts location tracking if it is not already running and is now
  /// possible. Safe to call repeatedly.
  Future<void> _retryLocation() async {
    if (_locationActive || !mounted) return;
    if (!await LocationService.instance.isAvailable()) return;
    if (!mounted) return;
    setState(() => _error = null);
    await _startLocation();
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
  /// Guards against overlapping layer setup.
  ///
  /// MapLibre can fire onStyleLoaded more than once per style, and the passes
  /// then race: the second tries to add layers the first already added
  /// ("Layer roadscan-pins-glow already exists", which surfaced as an
  /// unhandled exception) while the first can still be mid-flight against a
  /// style the platform reports as not ready.
  bool _layerSetupRunning = false;

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    if (_layerSetupRunning) return;
    _layerSetupRunning = true;
    try {
      await _installLayers(c);
    } finally {
      _layerSetupRunning = false;
    }
  }

  Future<void> _installLayers(MapLibreMapController c) async {
    // Reveal the map FIRST, before adding anything to it.
    //
    // This flag gates a full-screen loading panel. Setting it only after every
    // layer had been added meant any one of them throwing left the panel up
    // permanently -- a blank screen over a perfectly good map. The basemap is
    // already drawn by the time this callback runs; everything below is
    // decoration on top of it, and none of it is worth hiding the map for.
    if (mounted && !_styleReady) setState(() => _styleReady = true);

    // Water goes down BEFORE the road contrast, so roads cross over the river
    // rather than the river cutting the network in half at every bridge.
    try {
      await MapLayers.addWater(c);
    } catch (e) {
      debugPrint('RoadScan: water layers unavailable: $e');
    }

    // Dark basemap only: `liberty` already draws roads with plenty of
    // contrast, but OpenFreeMap's `dark` style makes them nearly invisible.
    // See MapLayers.addRoadContrast.
    if (_builtStyle == AppTheme.mapStyleDark) {
      try {
        await MapLayers.addRoadContrast(
          c,
          neon: ThemeController.instance.isNeon,
        );
      } catch (e) {
        debugPrint('RoadScan: road contrast layer unavailable: $e');
      }
    }

    // ...and the corridor AFTER them, because its whole job is to stand out
    // from the road network it is part of.
    try {
      await MapLayers.addCorridor(c);
    } catch (e) {
      debugPrint('RoadScan: corridor layer unavailable: $e');
    }

    // Buildings are NOT added here -- see _ensureBuildings, called at the end
    // of this method and again whenever the camera settles.

    // Everything outside the operating square, hatched off.
    try {
      String? hatchId;
      final hatch = await MapLayers.makeHatchImage();
      if (hatch != null) {
        hatchId = 'roadscan-hatch';
        await c.addImage(hatchId, hatch);
      }
      await MapLayers.addBoundsMask(c, hatchImageId: hatchId);
    } catch (e) {
      // The camera clamp is the real restriction; the mask is the visible
      // explanation of it. Losing the mask must not lose the map.
      debugPrint('RoadScan: bounds mask unavailable: $e');
    }

    // Wrapped, and the source is dropped first.
    //
    // This was the one unguarded add left in here, and adding a GeoJSON source
    // that already exists throws. On a repeat style-load that exception
    // escaped, so the line below that sets _styleReady never ran and the user
    // was left looking at the loading spinner over a blank map -- a cosmetic
    // layer failure taking down the whole screen.
    try {
      await MapLayers.addPinSource(c);
      await MapLayers.addPinLayers(c);
    } catch (e) {
      debugPrint('RoadScan: pin layers unavailable: $e');
    }

    // Above the hazard pins: where you are is the one thing that must never be
    // occluded, and on a dense stretch a cluster of pins would otherwise bury
    // it.
    try {
      await MapLayers.addUserLayers(
        c,
        dark: _builtStyle == AppTheme.mapStyleDark,
      );
      // Re-seed immediately: on a theme re-style the stream will not tick
      // again until the user physically moves, so without this the marker
      // would simply vanish until then.
      final last = LocationService.instance.lastKnown;
      if (last != null) {
        await c.setGeoJsonSource(
          MapLayers.userSourceId,
          MapLayers.userGeoJson(last.latitude, last.longitude),
        );
      }
    } catch (e) {
      debugPrint('RoadScan: user layers unavailable: $e');
    }

    // Place names LAST, so they sit on top of everything.
    //
    // These four are the only places the app covers, so knowing which one you
    // are looking at outranks every other label on the map -- including the
    // roads and the corridor, which previously drew across the text.
    //
    // The 3D buildings would still bury them, because _ensureBuildings adds
    // those lazily long after this method returns and a plain add lands on
    // top of the stack. They are anchored below the pin layers instead; see
    // MapLayers.addMlBuildings.
    try {
      await MapLayers.addAreaLabels(
        c,
        dark: _builtStyle == AppTheme.mapStyleDark,
      );
    } catch (e) {
      debugPrint('RoadScan: area labels unavailable: $e');
    }

    // A re-style keeps the camera, so there is nothing to fly to and the GPS
    // subscription and pin cache are still live. Re-running the first-open
    // path here would replay the fly-in and yank the camera off wherever the
    // user was.
    if (_cameraReady) {
      await _pushPins();
      await _ensureBuildings();
      return;
    }

    await c.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _area.center,
          zoom: _area.zoom,
          tilt: AppConfig.initialPitch,
          bearing: 0,
        ),
      ),
      duration: AppConfig.areaEntryDuration,
    );
    if (!mounted) return;
    setState(() {
      _pitch = AppConfig.initialPitch;
      _bearing = 0;
      _cameraReady = true;
    });

    await _startLocation();
    await _refreshPins();
    // Last: the fly-in has finished by now, so the heavy geometry upload
    // lands on an idle frame rather than competing with the animation.
    await _ensureBuildings();
  }

  /// True once the building extrusion exists in the CURRENT style object.
  /// Cleared on every style swap, because setStyle discards it.
  bool _buildingsAdded = false;

  /// Zoom at which the buildings are worth uploading.
  ///
  /// Must stay BELOW MapLayers.buildingsMinZoom, or the camera can settle at a
  /// zoom where the layer would draw but the geometry has not been uploaded
  /// yet, and the skyline pops in a beat late.
  ///
  /// Adding it while the camera is wider than this pushes 3.3 MB of geometry
  /// across the platform channel for something that will not be drawn -- which
  /// is most of the cost of a dark <-> light switch, since the map opens at
  /// minZoom.
  static const double _buildingsZoomThreshold =
      MapLayers.buildingsMinZoom - 0.8;

  /// Adds the building extrusion if it is missing and the camera is close
  /// enough to see it. Safe and cheap to call repeatedly.
  Future<void> _ensureBuildings() async {
    if (_buildingsAdded) return;
    final c = _controller;
    if (c == null || !_styleReady) return;

    final zoom = c.cameraPosition?.zoom ?? AppConfig.initialZoom;
    if (zoom < _buildingsZoomThreshold) return;

    // Set before awaiting: onCameraIdle can fire again mid-upload, and a
    // second pass would add a duplicate layer.
    _buildingsAdded = true;
    try {
      await MapLayers.addMlBuildings(
        c,
        dark: _builtStyle == AppTheme.mapStyleDark,
      );
    } catch (e) {
      // No fallback to the basemap's own extrusion, deliberately.
      //
      // An empty skyline is better than a wrong one: the OSM alternative is
      // 151 footprints over 81 km2, 8 of them triangles and none with a real
      // height, which renders as a handful of stray wedges scattered across
      // the map. That reads as a rendering fault rather than as data.
      debugPrint('RoadScan: buildings layer unavailable: $e');
      _buildingsAdded = false; // let a later camera move retry
    }
  }

  /// Pushes the cached pins into the (possibly new) style's source.
  Future<void> _pushPins() async {
    await _controller?.setGeoJsonSource(
      MapLayers.pinSourceId,
      MapLayers.pinsGeoJson(_reports),
    );
  }

  /// True when a fix falls inside the operating square.
  ///
  /// Matters because the camera is hard-clamped to that square: flying to a
  /// position outside it does not show the user where they are, it shoves the
  /// camera against the nearest boundary and strands them looking at the edge
  /// of the mask. Better to stay on the area they actually chose.
  static bool _withinBounds(double lat, double lon) {
    final sw = AppConfig.corridorSouthWest;
    final ne = AppConfig.corridorNorthEast;
    return lat >= sw.latitude &&
        lat <= ne.latitude &&
        lon >= sw.longitude &&
        lon <= ne.longitude;
  }

  Future<void> _startLocation() async {
    try {
      final pos = await LocationService.instance.currentPosition();
      _locationActive = true;
      // Plot the marker before deciding where the camera goes -- even when the
      // user is outside the corridor and the camera stays put, they should be
      // able to see their own position relative to the square.
      _updateUserMarker(pos);
      if (_withinBounds(pos.latitude, pos.longitude)) {
        await _flyTo(LatLng(pos.latitude, pos.longitude));
      } else {
        // Outside the corridor -- stay on the chosen area and say why, rather
        // than silently parking at the boundary.
        await _flyTo(_area.center);
        if (mounted) {
          setState(() => _error =
              'You are outside the mapped corridor, so the map is showing '
              '${_area.name}. Reporting still works once you are inside the '
              'highlighted square.');
        }
      }

      _locationActive = true;
      _positionSub?.cancel();
      _positionSub = LocationService.instance.watch().listen((p) {
        // Proximity alerting rides on the same position stream that drives the
        // map dot -- one GPS subscription, not two.
        ProximityAlerts.instance.onPosition(p, _reports);
        _updateLiveAlert(p);
        _updateUserMarker(p);
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
      duration: AppConfig.flyToDuration,
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

  /// Moves the position marker. Cheap enough to run on every GPS tick --
  /// it rewrites a one-feature GeoJSON source, it does not rebuild any widget.
  void _updateUserMarker(Position p) {
    _controller?.setGeoJsonSource(
      MapLayers.userSourceId,
      MapLayers.userGeoJson(p.latitude, p.longitude),
    );
  }

  /// Recentres on the user's live position, if that position is somewhere the
  /// camera is allowed to go.
  Future<void> _centreOnMe() async {
    try {
      final pos = await LocationService.instance.currentPosition();
      if (!mounted) return;
      if (!_withinBounds(pos.latitude, pos.longitude)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('You are outside the mapped corridor.'),
            duration: Duration(seconds: 3),
          ));
        return;
      }
      await _flyTo(LatLng(pos.latitude, pos.longitude));
    } on LocationUnavailable catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(e.message),
          duration: const Duration(seconds: 3),
        ));
    }
  }

  Future<void> _switchArea() async {
    // Popping back to the launch screen keeps one source of truth for the area
    // rather than duplicating the picker inside the map.
    //
    // popUntil rather than a single pop: the user may have a detail sheet or a
    // pushed screen above the map, and a lone pop would only close that, which
    // looks like the button did nothing.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ---------------------------------------------------------------------------
  // Camera controls
  // ---------------------------------------------------------------------------

  void _setPitch(double value) {
    setState(() => _pitch = value);
    _controller?.animateCamera(
      CameraUpdate.tiltTo(value),
      duration: AppConfig.pitchDuration,
    );
  }

  void _resetBearing() {
    setState(() => _bearing = 0);
    _controller?.animateCamera(
      CameraUpdate.bearingTo(0),
      duration: AppConfig.bearingResetDuration,
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


  /// Applies a theme change to the live map without rebuilding it.
  ///
  /// Takes one of two paths, and the distinction matters a lot for how this
  /// feels on a slower phone:
  ///
  ///   SAME basemap (dark <-> neon) -- only the road overlay differs, so
  ///     nothing is re-styled. setStyle would discard every layer and source
  ///     and force the 15,121-polygon building source to be re-uploaded to the
  ///     native side and re-tessellated, which is the stall where the
  ///     buildings visibly vanish and redraw. Swapping just the road layer
  ///     avoids all of it.
  ///
  ///   DIFFERENT basemap (to or from light) -- the basemap itself has to
  ///     change, so a full setStyle is unavoidable.
  void _syncStyle(String styleUrl, AppThemeKind kind) {
    if (_builtStyle == null || _builtKind == kind) return;
    if (_styleSwapInFlight) return;
    final c = _controller;
    if (c == null) return;

    final sameBasemap = _builtStyle == styleUrl;
    _builtKind = kind;

    if (sameBasemap) {
      // Cheap path: rebuild only the road contrast layer.
      //
      // The corridor has to be re-stacked afterwards. A re-added layer goes on
      // TOP of the style, so rebuilding the roads would bury the corridor
      // underneath them and the highlight would silently disappear on the
      // first neon toggle. Re-adding it is cheap -- 388 points against the
      // 15,121-polygon building source this path exists to protect.
      _styleSwapInFlight = true;
      MapLayers.addRoadContrast(c, neon: kind == AppThemeKind.neon)
          .then((_) => MapLayers.addCorridor(c))
          .catchError((Object e) =>
              debugPrint('RoadScan: road overlay swap failed: $e'))
          .whenComplete(() => _styleSwapInFlight = false);
      return;
    }

    _styleSwapInFlight = true;
    _builtStyle = styleUrl;
    // setStyle discards every layer, the buildings included, so the next
    // _ensureBuildings has to re-add them.
    _buildingsAdded = false;

    // NOTE: _styleReady is deliberately NOT cleared here.
    //
    // It gates the full-screen loading panel, which is correct on first open
    // but wrong for a theme swap: MapLibre keeps rendering the OLD style until
    // the new one is ready, so blanking the screen hides a perfectly good map
    // behind a spinner and makes a repaint look like a reload.
    //
    // MapStyle.resolve hands over the style as JSON with the basemap's own
    // building layers already removed. Passing the raw URL instead let those
    // layers render for a frame or two before we could delete them, which is
    // the blink of stray OSM wedges visible on every switch.
    MapStyle.resolve(styleUrl)
        .then((style) => c.setStyle(style))
        .whenComplete(() => _styleSwapInFlight = false);
  }

  /// The first style, already rewritten by [MapStyle]. Null until the fetch
  /// completes, during which the map is not built at all -- constructing it
  /// with the raw URL would show the basemap's own buildings for a moment,
  /// which is the very flash this avoids.
  String? _initialStyle;

  /// Built exactly once. Theme changes go through [_syncStyle], never through
  /// a rebuild -- see [_builtStyle].
  Widget _buildMap(String styleUrl, AppThemeKind kind) {
    if (_mapWidget != null) return _mapWidget!;

    final resolved = _initialStyle;
    if (resolved == null) {
      // Kick off the rewrite; rebuild once it lands.
      MapStyle.resolve(styleUrl).then((style) {
        if (!mounted) return;
        setState(() => _initialStyle = style);
        // Warm the other basemap so the first theme switch does not pay for
        // a fetch on top of the swap.
        final other = styleUrl == AppTheme.mapStyleLight
            ? AppTheme.mapStyleDark
            : AppTheme.mapStyleLight;
        MapStyle.warm(other);
      });
      return const SizedBox.expand();
    }

    _builtStyle = styleUrl;
    _builtKind = kind;

    return _mapWidget = RepaintBoundary(
      child:
          MapLibreMap(
            // The rewritten JSON, not the URL -- see [_initialStyle].
            styleString: resolved,
            // Opens wide and flat, then flies in to the area (see
            // _onStyleLoaded). Starting at the final zoom would make the
            // launch-screen "dive in" transition stop dead the moment the map
            // appeared.
            initialCameraPosition: CameraPosition(
              target: _area.center,
              zoom: AppConfig.areaEntryZoom,
              tilt: 0,
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
            // MapLibre's own location component is OFF; RoadScan draws the
            // position itself (MapLayers.addUserLayers). Two reasons: the
            // built-in dot is a fixed size that becomes almost invisible at
            // corridor zoom, and its tracking mode had to be disabled anyway
            // -- with the camera clamped to the operating square, tracking a
            // user standing OUTSIDE it pinned the view to the boundary on
            // every GPS tick and made the map impossible to pan.
            myLocationEnabled: false,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            tiltGesturesEnabled: true,
            rotateGesturesEnabled: true,
            trackCameraPosition: true,
            // MapLibre's own compass is switched OFF, not repositioned. It
            // landed top-right under the stats bar, and it duplicated the
            // compass already built into PitchControl, which sits next to the
            // tilt slider it belongs with. Two compasses in different corners
            // disagreeing about where north is looks like a bug.
            compassEnabled: false,
            // The attribution "i" defaults to the bottom-right, where it
            // collided with the action bar. Moved to the top-left under the
            // menu button: still present (it is a licence requirement, not
            // decoration) but out of the thumb path.
            attributionButtonPosition: AttributionButtonPosition.topLeft,
            attributionButtonMargins: const math.Point(12, 74),
            onCameraIdle: () {
              // Zoomed in far enough to need the buildings? Upload them now.
              // This is what keeps a theme switch cheap while zoomed out.
              _ensureBuildings();

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

    return ValueListenableBuilder<AppThemeKind>(
      valueListenable: ThemeController.instance.kind,
      builder: (context, kind, _) {
        final styleUrl = AppTheme.mapStyleFor(kind);
        // Swap the basemap after this frame: setStyle talks to the platform
        // channel, and calling it during build would mutate the map while it
        // is being laid out.
        if (_builtKind != null && _builtKind != kind) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _syncStyle(styleUrl, kind));
        }
        return _buildScaffold(context, c, styleUrl, kind);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, RoadScanColors c,
      String styleUrl, AppThemeKind kind) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: AppDrawer(deviceId: _deviceId.isEmpty ? '00000000' : _deviceId),
      body: Stack(
        children: [
          _buildMap(styleUrl, kind),

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
                        // Had no outline at all, which left it the one piece
                        // of map chrome with no edge.
                        shape: CircleBorder(
                          side: BorderSide(color: c.chromeBorder, width: 1.0),
                        ),
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
                      // Theme and home, as round glass buttons stacked on the
                      // right. Both were previously only reachable through the
                      // drawer (theme) or by tapping the area name (home),
                      // neither of which is discoverable mid-ride.
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Neon, with the same lit-when-active treatment as
                          // the launch screen so the control means the same
                          // thing in both places.
                          ValueListenableBuilder<AppThemeKind>(
                            valueListenable: ThemeController.instance.kind,
                            builder: (context, k, _) => _MapGlassButton(
                              icon: Icons.auto_awesome_outlined,
                              tooltip: k == AppThemeKind.neon
                                  ? 'Neon on'
                                  : 'Neon',
                              active: k == AppThemeKind.neon,
                              onTap: () =>
                                  ThemeController.instance.toggleNeon(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ValueListenableBuilder<AppThemeKind>(
                            valueListenable: ThemeController.instance.kind,
                            builder: (context, k, _) {
                              final target = k == AppThemeKind.light
                                  ? AppThemeKind.dark
                                  : AppThemeKind.light;
                              return _MapGlassButton(
                                icon: target.icon,
                                tooltip: 'Switch to ${target.label}',
                                onTap: () => ThemeController.instance
                                    .toggleBrightness(),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          // Reset bearing to north. The needle rotates with
                          // the map so it always shows which way north
                          // currently is, and tapping snaps back -- the same
                          // convention as the compass in PitchControl, which
                          // is easy to miss over on the left.
                          _MapGlassButton(
                            icon: Icons.navigation_rounded,
                            tooltip: 'Face north',
                            iconRotation: -_bearing * math.pi / 180.0,
                            onTap: _resetBearing,
                          ),
                          const SizedBox(height: 8),
                          // Needed now that the camera no longer follows GPS
                          // automatically -- without this there would be no
                          // way back to your own position.
                          _MapGlassButton(
                            icon: Icons.my_location_rounded,
                            tooltip: 'Centre on me',
                            onTap: _centreOnMe,
                          ),
                          const SizedBox(height: 8),
                          _MapGlassButton(
                            icon: Icons.grid_view_rounded,
                            tooltip: 'Change area',
                            onTap: _switchArea,
                          ),
                        ],
                      ),
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

/// A round frosted button for the map's own controls.
///
/// Matches the action bar's material so the map chrome reads as one system
/// rather than as buttons borrowed from three different screens.
class _MapGlassButton extends StatelessWidget {
  const _MapGlassButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconRotation,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Radians. Used by the compass so its needle tracks the map's bearing.
  final double? iconRotation;

  /// Lit state, for controls that are on/off rather than momentary.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final glass = c.isDark ? const Color(0xFF16293A) : Colors.white;

    return Tooltip(
      message: tooltip,
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: active
                ? c.accent.withValues(alpha: 0.22)
                : glass.withValues(alpha: c.isDark ? 0.55 : 0.62),
            shape: CircleBorder(
              side: BorderSide(
                color: active ? c.accent : c.chromeBorder,
                width: active ? 1.6 : 1.0,
              ),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: iconRotation == null
                    ? Icon(icon,
                        size: 19,
                        color: active ? c.accent : c.textPrimary)
                    : Transform.rotate(
                        angle: iconRotation!,
                        child: Icon(icon, size: 19, color: c.textPrimary),
                      ),
              ),
            ),
          ),
        ),
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
