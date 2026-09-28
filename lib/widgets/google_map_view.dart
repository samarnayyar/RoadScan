import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;

import '../config/app_config.dart';
import '../models/detection.dart' show SeverityClass;
import '../models/hazard_report.dart';

/// Google's map, shown in place of the MapLibre one at the same camera.
///
/// Why both exist
/// --------------
/// They answer different questions. MapLibre draws what RoadScan knows -- the
/// corridor, the hazard markers, the road bands, the 3D craters -- on vector
/// tiles it styles itself, with no key and no quota. Google answers what a
/// junction actually looks like, with satellite imagery and a road network
/// kept current by a company whose whole business that is. Neither replaces
/// the other, so the app carries both and hands the user the switch.
///
/// What this view deliberately does NOT do
/// ---------------------------------------
/// The craters and road bands are not redrawn here. They are MapLibre
/// fill-extrusion and line layers driven by expressions; Google's Flutter API
/// has no equivalent, and faking them with polygons would be a second
/// renderer to keep in step with the first for a worse result. The hazards
/// still appear as markers with the same severity colours and the same tap
/// behaviour, so nothing is lost except the 3D -- which is exactly what the
/// other view is for.
class GoogleMapView extends StatefulWidget {
  const GoogleMapView({
    super.key,
    required this.initialCamera,
    required this.reports,
    required this.onCameraIdle,
    required this.onHazardTapped,
    required this.onMapTapped,
  });

  /// Where the MapLibre view was left. Handed over rather than recomputed, so
  /// the switch reads as the same place in a different skin.
  final gmap.CameraPosition initialCamera;

  final List<HazardReport> reports;

  /// Reports the camera back so the OTHER view can pick it up on the way
  /// back. Without this the switch would be one-way: you could carry a
  /// position into Google and never carry it out.
  final void Function(gmap.CameraPosition camera) onCameraIdle;

  final void Function(HazardReport report) onHazardTapped;
  final VoidCallback onMapTapped;

  @override
  State<GoogleMapView> createState() => _GoogleMapViewState();
}

class _GoogleMapViewState extends State<GoogleMapView> {
  gmap.GoogleMapController? _controller;
  gmap.CameraPosition? _camera;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Google's stock markers, tinted by severity.
  ///
  /// Not the generated teardrops the MapLibre view uses: those are registered
  /// into MapLibre's own image atlas, and reproducing them here would mean
  /// rasterising four bitmaps a second time for a marker set the user only
  /// sees while this view is open. The hues are the same, which is what
  /// carries the meaning across the switch.
  static double _hueFor(SeverityClass s) => switch (s) {
        SeverityClass.low => gmap.BitmapDescriptor.hueGreen,
        SeverityClass.medium => gmap.BitmapDescriptor.hueYellow,
        SeverityClass.high => gmap.BitmapDescriptor.hueOrange,
        SeverityClass.critical => gmap.BitmapDescriptor.hueRed,
      };

  Set<gmap.Marker> get _markers => {
        for (final r in widget.reports)
          gmap.Marker(
            markerId: gmap.MarkerId(r.id),
            position: gmap.LatLng(r.lat, r.lon),
            icon: gmap.BitmapDescriptor.defaultMarkerWithHue(
              _hueFor(r.severity),
            ),
            // The app's own card opens instead of Google's info window, so
            // one hazard reads the same either side of the switch.
            consumeTapEvents: true,
            onTap: () => widget.onHazardTapped(r),
          ),
      };

  @override
  Widget build(BuildContext context) {
    return gmap.GoogleMap(
      initialCameraPosition: widget.initialCamera,
      markers: _markers,
      mapType: gmap.MapType.hybrid,
      // Google's own chrome is off: RoadScan already has a tilt slider, a
      // compass and a locate button, and a second set in the same corners
      // would overlap them and mean the same controls do different things
      // depending on which view is open.
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      myLocationButtonEnabled: false,
      compassEnabled: false,
      // The blue dot itself stays -- that one is information, not a control.
      // Permission is already held by the time this view can be reached.
      myLocationEnabled: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
      minMaxZoomPreference: const gmap.MinMaxZoomPreference(
        AppConfig.minZoom,
        AppConfig.maxZoom,
      ),
      // The same operating square the other view is fenced to, so panning
      // cannot wander off the corridor in one view and not the other.
      cameraTargetBounds: gmap.CameraTargetBounds(
        gmap.LatLngBounds(
          southwest: gmap.LatLng(
            AppConfig.corridorSouthWest.latitude,
            AppConfig.corridorSouthWest.longitude,
          ),
          northeast: gmap.LatLng(
            AppConfig.corridorNorthEast.latitude,
            AppConfig.corridorNorthEast.longitude,
          ),
        ),
      ),
      onMapCreated: (c) => _controller = c,
      onTap: (_) => widget.onMapTapped(),
      onCameraMove: (cam) => _camera = cam,
      onCameraIdle: () {
        final cam = _camera;
        if (cam != null) widget.onCameraIdle(cam);
      },
    );
  }
}
