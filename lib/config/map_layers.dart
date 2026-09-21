import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/detection.dart';
import '../models/hazard_report.dart';

/// Builds the style layers RoadScan adds on top of the base map, and the
/// GeoJSON the pin layers read.
///
/// Kept out of the widget so the visual encoding (what colour means what, what
/// fades, what pulses) can be reasoned about and changed in one place.
class MapLayers {
  MapLayers._();

  static const String buildingsLayerId = 'roadscan-3d-buildings';
  static const String roadsLayerId = 'roadscan-road-contrast';
  static const String pinSourceId = 'roadscan-pins';
  static const String pinGlowLayerId = 'roadscan-pins-glow';
  static const String pinCoreLayerId = 'roadscan-pins-core';
  static const String pinCountLayerId = 'roadscan-pins-count';

  /// The vector source name used by OpenMapTiles-schema styles, which is what
  /// OpenFreeMap serves. If you switch to a differently-schema'd tile provider,
  /// this and [_buildingSourceLayer] are what break.
  static const String _vectorSourceId = 'openmaptiles';
  static const String _buildingSourceLayer = 'building';

  /// Extrudes OSM building footprints into 3D.
  ///
  /// This is what makes the map read as Google-Earth-like rather than as a flat
  /// slippy map, and combined with camera pitch it's the project's visual
  /// centrepiece.
  ///
  /// `render_height` / `render_min_height` are OpenMapTiles-schema attributes
  /// derived from OSM `height` / `building:levels`. Coverage in Bidholi is
  /// patchy -- many buildings carry no height tag, so the coalesce fallback
  /// gives them a nominal 6m (roughly two storeys) instead of extruding them to
  /// zero and leaving visible holes in the skyline.
  static Future<void> addBuildings(MapLibreMapController c) async {
    await c.addFillExtrusionLayer(
      _vectorSourceId,
      buildingsLayerId,
      FillExtrusionLayerProperties(
        fillExtrusionColor: [
          'interpolate',
          ['linear'],
          ['coalesce', ['get', 'render_height'], 6],
          0, '#d7dbe0',
          20, '#c2c8d0',
          60, '#aab2bd',
        ],
        fillExtrusionHeight: ['coalesce', ['get', 'render_height'], 6],
        fillExtrusionBase: ['coalesce', ['get', 'render_min_height'], 0],
        // Slightly translucent so pins behind a building stay perceptible.
        fillExtrusionOpacity: 0.85,
      ),
      sourceLayer: _buildingSourceLayer,
      // Below z14 the footprints are too small to read and extruding thousands
      // of them is wasted GPU time.
      minzoom: 14.0,
      enableInteraction: false,
    );
  }

  /// Converts pins to GeoJSON.
  ///
  /// Colour and opacity are baked into feature properties rather than computed
  /// with style expressions. Confidence decays continuously, so expressing it
  /// as an expression over `last_confirmed_at` would need the style re-
  /// evaluated on a timer anyway; doing it in Dart keeps one source of truth.
  static Map<String, dynamic> pinsGeoJson(List<HazardReport> reports) => {
        'type': 'FeatureCollection',
        'features': [
          for (final r in reports)
            {
              'type': 'Feature',
              'id': r.id,
              'geometry': {
                'type': 'Point',
                'coordinates': [r.lon, r.lat],
              },
              'properties': {
                'id': r.id,
                'color': _hex(r),
                'opacity': r.markerOpacity,
                'severity': r.severity.name,
                'hazard': r.hazard.name,
                'confirmations': r.confirmationCount,
                'countLabel':
                    r.confirmationCount > 1 ? '${r.confirmationCount}' : '',
                'isFresh': r.isFresh,
                'isStale': r.isStale,
                'isFixed': r.isFixed,
                // Fixed pins shrink; critical pins grow. Size carries urgency
                // even for a colour-blind viewer.
                'radius': r.isFixed ? 6.0 : _radiusFor(r),
                'strokeOpacity': r.isStale ? 0.95 : 0.65,
                'strokeWidth': r.isStale ? 2.4 : 1.6,
              },
            },
        ],
      };

  static Future<void> addPinLayers(MapLibreMapController c) async {
    // Glow sits under the core circle and is filtered to pins under 24h old,
    // giving fresh reports a halo that draws the eye without a new colour.
    await c.addCircleLayer(
      pinSourceId,
      pinGlowLayerId,
      CircleLayerProperties(
        circleRadius: ['*', ['get', 'radius'], 2.2],
        circleColor: ['get', 'color'],
        circleOpacity: 0.28,
        circleBlur: 0.9,
      ),
      filter: ['==', ['get', 'isFresh'], true],
      enableInteraction: false,
    );

    await c.addCircleLayer(
      pinSourceId,
      pinCoreLayerId,
      CircleLayerProperties(
        circleRadius: ['get', 'radius'],
        circleColor: ['get', 'color'],
        circleOpacity: ['get', 'opacity'],
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: ['get', 'strokeWidth'],
        circleStrokeOpacity: ['get', 'strokeOpacity'],
      ),
    );

    // Confirmation-count badge. Empty string for single reports so we don't
    // stamp a "1" on every pin on the map.
    await c.addSymbolLayer(
      pinSourceId,
      pinCountLayerId,
      SymbolLayerProperties(
        textField: ['get', 'countLabel'],
        textSize: 11.0,
        textColor: '#FFFFFF',
        textHaloColor: 'rgba(0,0,0,0.45)',
        textHaloWidth: 0.8,
        textAllowOverlap: true,
        textIgnorePlacement: true,
        textFont: const ['Noto Sans Regular'],
      ),
      enableInteraction: false,
    );
  }

  /// Critical pins render larger so severity survives a glance at a tilted map
  /// where distant pins are already small.
  static double _radiusFor(HazardReport r) => switch (r.severity) {
        SeverityClass.low => 7.0,
        SeverityClass.medium => 8.5,
        SeverityClass.high => 10.5,
        SeverityClass.critical => 12.5,
      };

  static String _hex(HazardReport r) {
    final c = r.color;
    final v = (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '#$v';
  }
}
