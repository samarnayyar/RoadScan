import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../config/hazard_3d.dart';
import '../config/hazard_zone.dart';
import '../config/map_layers.dart';
import '../config/pin_icons.dart';
import '../services/theme_controller.dart';
import '../models/hazard_report.dart';
import '../services/location_service.dart';
import '../services/map_style.dart';
import '../services/proximity_alerts.dart';
import '../services/supabase_service.dart';
import 'package:image_picker/image_picker.dart';

import '../services/device_identity.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/pin_popup.dart';
import '../widgets/app_drawer.dart';
import '../widgets/glass_action_bar.dart';
import '../widgets/google_map_view.dart';
import '../widgets/hazard_alert_banner.dart';
import '../widgets/map_mode_switch.dart';
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

  /// The pin whose popup is showing, if any. Held as the report rather than
  /// the id so the card keeps rendering unchanged while a refresh is in
  /// flight -- looking up by id every build made the popup flicker empty for
  /// a frame each time realtime fired.
  /// Marks the tilt slider + button rail, so the card can be kept off them.
  ///
  /// Measured rather than assumed: their height depends on the theme buttons
  /// present and on the device's safe-area inset, and a hardcoded guess would
  /// drift the moment either changed.
  final GlobalKey _controlsKey = GlobalKey();

  /// Which map is under the chrome. See MapMode.
  MapMode _mapMode = MapMode.roadscan;

  /// The camera the OTHER view was left at, so switching back returns to the
  /// same place rather than resetting to the area centre.
  ///
  /// Held as a plain record instead of either library's CameraPosition: both
  /// define their own, and storing one would make the field lie about which
  /// view owns it.
  ({LatLng target, double zoom, double tilt, double bearing})? _handoverCamera;

  HazardReport? _selectedPin;

  /// Where the selected pin currently sits on screen, in LOGICAL pixels.
  ///
  /// Null while the camera is moving. The card is anchored to the pin rather
  /// than parked at the bottom of the screen, so it has to follow the pin --
  /// and MapLibre only hands back a screen position on request, one platform
  /// round trip at a time. Asking every frame of a pan would be far too
  /// expensive, so the card hides during movement and re-anchors on idle.
  math.Point<double>? _pinAnchor;

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

  /// The area the CAMERA is over, which is not always the one that was picked.
  ///
  /// The header used to show the chosen area forever, so panning up the
  /// corridor to Kandholi left it still insisting you were at Nanda Ki
  /// Chowki. The picker chooses a starting point; the header reports where
  /// you actually are. Null until the first camera idle, when it falls back
  /// to the chosen area.
  CampusArea? _viewArea;

  CampusArea get _shownArea => _viewArea ?? _area;

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
    // Live pins. The callback carries no payload -- it means "refetch" -- so
    // one definition of what belongs on the map stays on the server. See
    // SupabaseService.subscribeToHazards.
    SupabaseService.instance.subscribeToHazards(() {
      if (mounted) _refreshPins();
    });
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
    SupabaseService.instance.unsubscribeFromHazards();
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

    // A tap that LANDS ON A PIN never reaches onMapClick.
    //
    // The pin layer is added with enableInteraction, which registers it with
    // the platform as an interactive layer. MapLibre then routes a tap that
    // hits one of its features to onFeatureTapped and stops -- onMapClick is
    // only called for taps that hit nothing interactive. So the handler below
    // is not a nicety or a duplicate: without it, tapping a pin does exactly
    // nothing, while tapping the bare map a few pixels away works via the
    // nearest-pin fallback. That asymmetry is what made this hard to spot.
    controller.onFeatureTapped.add((point, coords, id, layerId, _) {
      // The pin dot far out, the crater rim once it has faded in. Both carry
      // the report id, so either opens the same card.
      if (layerId != MapLayers.pinLayerId && layerId != Hazard3d.rimLayerId) {
        return;
      }
      _selectPinById(id);
    });
  }

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
      await Hazard3d.addLayers(c);

      // Before the layer that names them: a symbol layer whose icon is not in
      // the atlas renders nothing, and says nothing about why.
      await PinIcons.register(c, HazardReport.severityColor);
      await MapLayers.addPinSource(c);
      await MapLayers.addPinLayers(c);

      // After the markers, anchored below them: a band is context for a pin,
      // never a thing that covers it. belowLayerId only works against a layer
      // that already exists, so this cannot move above the call that adds it.
      await HazardZone.addLayers(c, belowLayerId: MapLayers.pinLayerId);
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
        // Re-resolve the open card against the new list, and drop it if the
        // pin no longer qualifies -- a report merged away or moved into
        // review must not keep showing a card for something not on the map.
        final open = _selectedPin;
        if (open != null) {
          _selectedPin = reports.where((r) => r.id == open.id).firstOrNull;
        }
      });
      await _controller?.setGeoJsonSource(
        MapLayers.pinSourceId,
        MapLayers.pinsGeoJson(reports),
      );
      // force: the report list changed, so the geometry must be rebuilt even
      // if the camera has not moved an inch.
      await _syncCrater(force: true);
      final mc = _controller;
      if (mc != null) {
        try {
          await HazardZone.update(mc, reports);
        } catch (e) {
          debugPrint('RoadScan: hazard zones unavailable: $e');
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load pins: $e');
    } finally {
      if (mounted) setState(() => _loadingPins = false);
    }
  }

  /// Renames the header to whichever area the camera is now closest to.
  void _updateViewArea() {
    final target = _controller?.cameraPosition?.target;
    if (target == null || !mounted) return;
    final area = AppConfig.nearestAreaTo(target.latitude, target.longitude);
    if (area.id == _shownArea.id) return;
    setState(() => _viewArea = area);
  }

  /// Recomputes where the selected pin is on screen.
  ///
  /// toScreenLocation returns DEVICE pixels; Flutter lays out in logical
  /// ones, so the result is divided by the device pixel ratio. On a 3x phone,
  /// skipping that would place the card three times too far down and right --
  /// off screen entirely.
  Future<void> _updatePinAnchor() async {
    final c = _controller;
    final pin = _selectedPin;
    if (c == null || pin == null) {
      if (_pinAnchor != null && mounted) setState(() => _pinAnchor = null);
      return;
    }
    try {
      final p = await c.toScreenLocation(LatLng(pin.lat, pin.lon));
      if (!mounted) return;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      setState(() => _pinAnchor = math.Point(p.x / dpr, p.y / dpr));
    } catch (e) {
      debugPrint('RoadScan: could not locate pin on screen: $e');
      if (mounted) setState(() => _pinAnchor = null);
    }
  }

  /// Zoom the crater geometry was last built for.
  double? _craterZoom;

  /// Rebuilds the crater geometry when the zoom has moved enough to matter.
  ///
  /// The crater is sized partly against the screen, so its ground geometry is
  /// a function of zoom. Gated on a 0.2-zoom delta so a pan or a pinch that
  /// barely moves does not re-serialise every polygon across the platform
  /// channel.
  Future<void> _syncCrater({bool force = false}) async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final zoom = c.cameraPosition?.zoom ?? AppConfig.initialZoom;
    if (!force && _craterZoom != null && (zoom - _craterZoom!).abs() < 0.2) {
      return;
    }
    _craterZoom = zoom;
    try {
      await Hazard3d.update(c, _reports, zoom: zoom);
    } catch (e) {
      // The crater is the headline visual, but the marker above it still
      // conveys the hazard. Losing it must not lose the map.
      debugPrint('RoadScan: crater update failed: $e');
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
        [MapLayers.pinLayerId, Hazard3d.rimLayerId],
        null,
      );
    } catch (e) {
      debugPrint('RoadScan: feature query failed: $e');
      return;
    }

    String? id = _idFromFeatures(features);

    // Fall back to nearest-pin-within-a-finger-width if the exact hit missed.
    id ??= _nearestPinId(coords, maxMeters: pad * _metresPerPixel(coords));

    // A tap on bare map dismisses an open card -- the same gesture that opens
    // one should close it.
    if (id == null) {
      if (_selectedPin != null && mounted) {
        setState(() {
          _selectedPin = null;
          _pinAnchor = null;
        });
      }
      return;
    }

    // Card, not the modal sheet.
    //
    // The sheet covers the map, which is the thing the rider was using to
    // decide where to go. The card answers "what is this, how bad, how
    // trusted" without hiding the route, and opens the sheet from its own
    // button for anyone who wants the photo history.
    _selectPinById(id);
  }

  /// Where and when the last finger went down, for spotting a double tap.
  Offset? _lastDownAt;
  DateTime? _lastDownTime;

  /// How close together in time two taps must be to count as one gesture.
  /// Android's own threshold is 300ms; a little longer here because the first
  /// tap does real work -- it opens a card -- so someone deciding to look
  /// closer is reacting to what they just saw.
  static const Duration _doubleTapWindow = Duration(milliseconds: 450);

  /// And how close in space, in logical pixels. Two deliberate taps on the
  /// same marker land within a finger's width; further apart and they are two
  /// separate taps that happened to be quick.
  static const double _doubleTapSlop = 44.0;

  /// Catches double taps before MapLibre's gesture detector eats them.
  ///
  /// This has to happen at the pointer level, and the reason is worth
  /// recording. Android's GestureDetector only reports onSingleTapConfirmed
  /// once the double-tap timeout has passed with no second tap; when a second
  /// tap does arrive it reports a double tap instead and the single-tap
  /// callback never fires -- for EITHER tap. MapLibre dispatches its map and
  /// feature click callbacks from onSingleTapConfirmed, so a double tap
  /// produces no Flutter callback at all, and a detector built on those
  /// callbacks can never see the gesture it is looking for. A Listener sees
  /// the raw pointers and, because it never claims them in the gesture arena,
  /// does not disturb panning, pinching or rotating.
  void _onPointerDown(PointerDownEvent e) {
    final now = DateTime.now();
    final prev = _lastDownAt;
    final prevAt = _lastDownTime;
    _lastDownAt = e.localPosition;
    _lastDownTime = now;

    if (prev == null ||
        prevAt == null ||
        now.difference(prevAt) > _doubleTapWindow ||
        (e.localPosition - prev).distance > _doubleTapSlop) {
      return;
    }

    // Consumed, so a third tap starts a new gesture rather than chaining.
    _lastDownAt = null;
    _lastDownTime = null;
    unawaited(_handleDoubleTap(e.localPosition));
  }

  /// A pin under the double tap means inspect it; anything else means zoom,
  /// which is what the gesture did before we took it over.
  Future<void> _handleDoubleTap(Offset localPosition) async {
    final c = _controller;
    if (c == null) return;

    // queryRenderedFeatures works in DEVICE pixels; a Listener reports
    // logical ones.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final point = math.Point<double>(
      localPosition.dx * dpr,
      localPosition.dy * dpr,
    );

    String? id;
    try {
      final hits = await c.queryRenderedFeatures(
        point,
        [MapLayers.pinLayerId, Hazard3d.rimLayerId],
        null,
      );
      id = _idFromFeatures(hits);
    } catch (e) {
      debugPrint('RoadScan: double-tap hit test failed: $e');
    }

    final report = id == null ? null : _reportById(id);
    if (report != null) {
      if (mounted) setState(() => _selectedPin = report);
      await _inspect(report);
      return;
    }

    try {
      await _zoomInAt(await c.toLatLng(point));
    } catch (e) {
      debugPrint('RoadScan: double-tap zoom failed: $e');
    }
  }

  /// Replaces MapLibre's double-tap zoom, which is disabled so the gesture
  /// can mean "inspect this hazard" on a pin. One zoom level toward the
  /// point, as the built-in does.
  Future<void> _zoomInAt(LatLng target) async {
    final c = _controller;
    if (c == null) return;
    final cam = c.cameraPosition;
    final zoom = math.min(
      (cam?.zoom ?? AppConfig.initialZoom) + 1.0,
      AppConfig.maxZoom,
    );
    try {
      await c.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: zoom,
            tilt: cam?.tilt ?? _pitch,
            bearing: cam?.bearing ?? _bearing,
          ),
        ),
        duration: const Duration(milliseconds: 260),
      );
    } catch (e) {
      debugPrint('RoadScan: zoom gesture failed: $e');
    }
  }

  HazardReport? _reportById(String id) {
    for (final r in _reports) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Opens the card for [id], which arrives from the feature's `id` member.
  ///
  /// A single tap shows the card and leaves the map exactly where it is.
  /// Flying in is a double tap, handled separately in [_onPointerDown],
  /// because reading a pin and studying one are different intentions: tapping
  /// a pin from the corridor view used to throw the camera down to street
  /// level, losing the route the user was actually looking at.
  void _selectPinById(String id) {
    final report = _reportById(id);
    if (report == null || !mounted) return;
    setState(() => _selectedPin = report);
    unawaited(_updatePinAnchor());
  }

  /// Moves the camera to where the hazard's 3D crater is actually readable.
  ///
  /// The crater's whole point is depth, and depth needs two things the default
  /// corridor view does not give it: enough zoom that the funnel is more than
  /// twenty pixels wide, and enough tilt that the eye sees the walls rather
  /// than looking straight down a flat ring. Tapping a pin is the moment the
  /// user asked to look at one hazard, so that is the moment to provide both.
  ///
  /// Both are raised, never lowered. Someone already at z19 studying the road
  /// should not be yanked back out, and someone who deliberately flattened the
  /// map to read street names keeps their choice of anything above the floor.
  Future<void> _inspect(HazardReport r) async {
    final c = _controller;
    if (c == null) return;

    final cam = c.cameraPosition;
    final zoom = math.max(cam?.zoom ?? AppConfig.initialZoom, _inspectZoom);
    final tilt = math.max(cam?.tilt ?? _pitch, _inspectPitch);

    try {
      await c.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(r.lat, r.lon),
            zoom: zoom,
            tilt: tilt,
            bearing: cam?.bearing ?? _bearing,
          ),
        ),
        duration: AppConfig.flyToDuration,
      );
      if (mounted) setState(() => _pitch = tilt);
      await _updatePinAnchor();
    } catch (e) {
      // A pin card that opened without the camera moving is still a usable
      // pin card.
      debugPrint('RoadScan: could not frame hazard ${r.id}: $e');
    }
  }

  /// Where a DOUBLE tap takes the camera.
  ///
  /// The crater is drawn close to the footprint measured from the photo, so a
  /// typical 0.9 m pothole is a few pixels at corridor zoom and about fifty
  /// here. This is deliberately a separate gesture: a single tap now leaves
  /// the camera alone, because the alternative -- drawing the pothole nine
  /// metres wide so it shows up next to the buildings -- is a lie about the
  /// road, and throwing the camera to street level uninvited is a lie about
  /// what the user asked for.
  static const double _inspectZoom = 21.0;

  /// Enough tilt to see down into the funnel without the far wall hiding the
  /// floor.
  static const double _inspectPitch = 50.0;

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
        showAppSnack(context, 'You are outside the mapped corridor.');
        return;
      }
      await _flyTo(LatLng(pos.latitude, pos.longitude));
    } on LocationUnavailable catch (e) {
      if (!mounted) return;
      showAppSnack(context, e.message, isError: true);
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

    showAppSnack(context, 'No image uploaded.',
        duration: const Duration(seconds: 2));
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
    // setStyle discards every source and layer, patches included. Without
    // this the tracker still claims them and refuses to re-add them, so the
    // photos silently never come back after a theme change.
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
  /// Swaps the map under the chrome, carrying the camera across.
  ///
  /// The point of the switch is that it is the SAME place in a different
  /// skin, so the camera has to travel with it. The outgoing view's position
  /// is captured here and handed to the incoming one; MapLibre's is read
  /// straight off the controller, Google's arrives through its camera-idle
  /// callback and is already stored.
  ///
  /// The open hazard card is closed on the way through. Its position is
  /// anchored to a pin's screen coordinates in the view being torn down, so
  /// leaving it up would park it over a map that has moved beneath it.
  void _toggleMapMode() {
    if (!mounted) return;

    if (_mapMode == MapMode.roadscan) {
      final cam = _controller?.cameraPosition;
      if (cam != null) {
        _handoverCamera = (
          target: cam.target,
          zoom: cam.zoom,
          tilt: cam.tilt,
          bearing: cam.bearing,
        );
      }
    }

    setState(() {
      _mapMode = _mapMode.other;
      _selectedPin = null;
      _pinAnchor = null;
    });
  }

  /// The camera the incoming view should open at.
  ///
  /// Falls back to the chosen area rather than to nothing, which is what
  /// happens on the very first switch before either view has reported a
  /// position.
  gmap.CameraPosition get _googleCamera {
    final h = _handoverCamera;
    return gmap.CameraPosition(
      target: gmap.LatLng(
        h?.target.latitude ?? _area.center.latitude,
        h?.target.longitude ?? _area.center.longitude,
      ),
      zoom: h?.zoom ?? _area.zoom,
      tilt: h?.tilt ?? _pitch,
      bearing: h?.bearing ?? _bearing,
    );
  }

  /// Stores Google's camera so the MapLibre view can be restored to it.
  ///
  /// MapLibre is not moved here, only recorded. It is not in the tree while
  /// this view is open, so its controller is gone; the position is applied on
  /// the way back, in _onStyleLoaded's camera setup.
  void _onGoogleCameraIdle(gmap.CameraPosition cam) {
    _handoverCamera = (
      target: LatLng(cam.target.latitude, cam.target.longitude),
      zoom: cam.zoom,
      tilt: cam.tilt,
      bearing: cam.bearing,
    );
  }

  /// Google's map, wired to the same reports and the same card.
  Widget _buildGoogleMap() {
    return GoogleMapView(
      initialCamera: _googleCamera,
      reports: _reports,
      onCameraIdle: _onGoogleCameraIdle,
      onHazardTapped: (r) {
        if (!mounted) return;
        // No screen anchor: the card's tail is positioned from MapLibre's
        // toScreenLocation, which does not exist here. It falls back to a
        // plain sheet, which is the honest thing to show rather than a tail
        // pointing at a guess.
        showPinDetailSheet(context, report: r, onChanged: _refreshPins);
      },
      onMapTapped: () {},
    );
  }

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
            // Taken over, not removed.
            //
            // MapLibre's own double-tap-to-zoom recognises the gesture and
            // consumes the second tap, so a double tap on a pin arrived as a
            // single one and the inspect gesture could never fire. Disabling
            // it lets both taps through; _onMapClick puts the zoom back for
            // taps that land on bare map, so the gesture still does what
            // everyone expects everywhere it is not a pin.
            doubleClickZoomEnabled: false,
            // Drop the anchor the moment the map starts moving. A card left
            // pinned to a stale screen position slides away from its own pin,
            // which looks far worse than briefly not being there.
            onCameraMove: (_) {
              if (_pinAnchor != null && mounted) {
                setState(() => _pinAnchor = null);
              }
            },
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
              _syncCrater();
              _updatePinAnchor();
              _updateViewArea();

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

  /// Places the callout so its tail tip lands on the pin.
  ///
  /// Three rules, in order of precedence:
  ///
  ///   1. Never cover the map's own controls. The tilt slider and the button
  ///      rail are how the user gets out of whatever the card is describing,
  ///      so a card sitting on top of them is worse than one badly placed.
  ///   2. Above the pin where there is room. The marker hangs above its own
  ///      tip, so "above" has to clear the whole marker, not just the point.
  ///   3. Below only as a fallback, and then pushed up if it would reach the
  ///      controls.
  ///
  /// Horizontally the card is centred on the pin but kept inside the screen,
  /// and the TAIL then slides within the card to keep pointing at the pin --
  /// otherwise a pin near the edge would get a card that has slid away with a
  /// tail aimed at empty road.
  Widget _buildPinCallout() {
    final pin = _selectedPin;
    final anchor = _pinAnchor;
    if (pin == null || anchor == null) return const SizedBox.shrink();

    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    const width = PinPopup.cardWidth;

    // The marker is anchored at its TIP, so it hangs entirely above the
    // hazard's position. A card placed above must clear the marker's full
    // height; one placed below needs only a small gap.
    const gap = 6.0;
    final clearance =
        PinIcons.maxLogicalHeight(MediaQuery.of(context).devicePixelRatio) +
            gap;

    // Enough for the tallest the card gets -- chip, four fact rows, photo and
    // the action strip. Only used to decide placement, so an overestimate
    // costs nothing but a slightly eager flip.
    const cardHeight = 250.0;

    // Below the header, and above the controls.
    final topLimit = pad.top + 64.0;
    final controlsTop = _controlsTop() ?? (size.height - 380.0);
    final bottomLimit = controlsTop - 8.0;

    // Kept inside the channel between the tilt slider and the button rail,
    // not merely inside the screen. Those two sit at the edges over the lower
    // half of the map, and a card centred on a pin near either edge would
    // land straight on top of them.
    const sideInset = 60.0;
    final minLeft = math.min(sideInset, math.max(0.0, size.width - width));
    final maxLeft = math.max(minLeft, size.width - sideInset - width);
    final left =
        (anchor.x - width / 2).clamp(minLeft, maxLeft).toDouble();
    final tailFraction =
        ((anchor.x - left) / width).clamp(0.0, 1.0).toDouble();

    final roomAbove = anchor.y - clearance - cardHeight >= topLimit;
    final fitsBelow = anchor.y + gap + cardHeight <= bottomLimit;

    // Below ONLY when it genuinely fits there. The earlier version placed the
    // card below and then slid it up to clear the controls, which for a pin
    // low on screen slid it straight over the marker it belonged to -- the
    // card ended up hiding the thing it was describing. Going above instead
    // can never do that, because above is measured from the marker's top.
    final above = roomAbove || !fitsBelow;

    double? top;
    double? bottom;
    if (above) {
      // Not clamped against the top, deliberately. Pulling the card back down
      // to fit under the header would walk it straight onto the marker, which
      // is the one thing this must never do. `above` is only chosen when
      // there is room above or the pin is low enough that there is plenty, so
      // the unclamped case needs a map area shorter than the card itself.
      bottom = size.height - anchor.y + clearance;
    } else {
      top = anchor.y + gap;
    }

    return Positioned(
      left: left,
      width: width,
      top: top,
      bottom: bottom,
      child: PinPopup(
        key: ValueKey(pin.id),
        report: pin,
        tailFraction: tailFraction,
        tailBelow: above,
        onDismiss: () => setState(() {
          _selectedPin = null;
          _pinAnchor = null;
        }),
        onOpenDetail: () => showPinDetailSheet(
          context,
          report: pin,
          onChanged: _refreshPins,
        ),
        onInspect: () => unawaited(_inspect(pin)),
      ),
    );
  }

  /// Top edge of the tilt slider and button rail, in logical pixels, or null
  /// before the first layout.
  double? _controlsTop() {
    final box = _controlsKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero).dy;
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
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            child: _buildMap(styleUrl, kind),
          ),

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
                        areaName: _shownArea.name,
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
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
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
                  key: _controlsKey,
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

          // The tapped-pin callout, anchored over its own pin.
          //
          // LAST in the stack, which is the whole point: a Stack paints its
          // children in order, so anything listed after this would cover it.
          // It sat before the chrome column and the tilt slider and the
          // button rail drew straight over the card. It is outside that
          // column because it is positioned against the map's own screen
          // coordinates rather than stacked in the chrome's layout flow.
          _buildPinCallout(),
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
