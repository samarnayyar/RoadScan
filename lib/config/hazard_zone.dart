import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/detection.dart' show SeverityClass;
import '../models/hazard_report.dart';

/// The stretch of road a hazard makes dangerous, drawn on the road itself.
///
/// A pin says "something is here". It does not say "ease off through this
/// bend", and at corridor zoom a marker is a few pixels while the decision a
/// rider has to make covers fifty metres of tarmac. This paints that stretch
/// in the hazard's own colour, so the map answers the question the rider
/// actually has -- which part of this road do I need to be careful on --
/// before they have tapped anything.
///
/// It is also what makes a hazard legible when zoomed out, where the marker
/// is too small to read: a coloured band on the route survives being small in
/// a way a marker does not.
///
/// Only hazards ON the corridor get a band
/// ---------------------------------------
/// The stretch is found by snapping the hazard onto the corridor polyline. A
/// report filed a hundred metres off the route -- in a yard, a field, a side
/// lane the app has no geometry for -- would snap to the nearest corridor
/// point anyway and paint a warning across a road that is perfectly fine.
/// That is worse than drawing nothing, so anything beyond [maxSnapM] is left
/// to its marker alone.
class HazardZone {
  HazardZone._();

  static const String sourceId = 'roadscan-zone';
  static const String glowLayerId = 'roadscan-zone-glow';
  static const String bandLayerId = 'roadscan-zone-band';

  /// How far off the corridor a hazard can be and still be considered on it.
  ///
  /// Generous enough for GPS drift and for a wide road whose centreline is
  /// not where the damage is, tight enough to exclude somewhere that is
  /// simply not this road.
  static const double maxSnapM = 30.0;

  /// Half-length of the painted stretch, by severity, in metres.
  ///
  /// Asymmetric in intent even though it is drawn symmetrically: the useful
  /// half is the approach, and since a rider can arrive from either end the
  /// band has to cover both. A critical hazard gets a longer run-up because
  /// it needs more warning, not because it is physically bigger.
  static double halfLengthFor(HazardReport r) => switch (r.severity) {
        SeverityClass.low => 18.0,
        SeverityClass.medium => 26.0,
        SeverityClass.high => 38.0,
        SeverityClass.critical => 52.0,
      };

  /// Corridor lines to snap against, set once the route geojson has loaded.
  ///
  /// Held here rather than re-read per refresh: it is 450-odd points that
  /// never change, and snapping every hazard against them happens on every
  /// pin refresh.
  static List<List<List<double>>> _routes = const [];

  static bool get hasRoutes => _routes.isNotEmpty;

  /// Takes the corridor GeoJSON and keeps just the line geometry.
  static void loadRoutes(Map<String, dynamic> corridor) {
    final out = <List<List<double>>>[];
    final features = corridor['features'];
    if (features is List) {
      for (final f in features) {
        if (f is! Map) continue;
        final g = f['geometry'];
        if (g is! Map || g['type'] != 'LineString') continue;
        final coords = g['coordinates'];
        if (coords is! List || coords.length < 2) continue;
        out.add([
          for (final c in coords)
            if (c is List && c.length >= 2)
              [(c[0] as num).toDouble(), (c[1] as num).toDouble()],
        ]);
      }
    }
    _routes = out;
  }

  static Map<String, dynamic> geoJson(List<HazardReport> reports) {
    final features = <Map<String, dynamic>>[];

    for (final r in reports) {
      // A pin already voted fixed should not still be closing a lane.
      if (r.isFixed) continue;
      final line = _stretchFor(r);
      if (line == null) continue;
      features.add({
        'type': 'Feature',
        'id': r.id,
        'properties': {
          'id': r.id,
          'color': _hex(r),
          // Flat, for the same reason the marker is: a band that fades with
          // age looks like a half-drawn band, not an old one.
          'opacity': 0.55,
        },
        'geometry': {'type': 'LineString', 'coordinates': line},
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// The corridor sub-line centred on [r], or null if it is not on the route.
  static List<List<double>>? _stretchFor(HazardReport r) {
    if (_routes.isEmpty) return null;

    List<List<double>>? bestRoute;
    var bestIndex = 0;
    var bestT = 0.0;
    var bestDist = double.infinity;

    final cosLat = math.cos(r.lat * math.pi / 180.0);

    for (final route in _routes) {
      for (var i = 0; i < route.length - 1; i++) {
        final (d, t) = _pointToSegment(
          r.lon,
          r.lat,
          route[i][0],
          route[i][1],
          route[i + 1][0],
          route[i + 1][1],
          cosLat,
        );
        if (d < bestDist) {
          bestDist = d;
          bestRoute = route;
          bestIndex = i;
          bestT = t;
        }
      }
    }

    if (bestRoute == null || bestDist > maxSnapM) return null;

    final a = bestRoute[bestIndex];
    final b = bestRoute[bestIndex + 1];
    final foot = [
      a[0] + (b[0] - a[0]) * bestT,
      a[1] + (b[1] - a[1]) * bestT,
    ];

    final half = halfLengthFor(r);
    final back = _walk(bestRoute, bestIndex, foot, half, cosLat, forward: false);
    final fwd = _walk(bestRoute, bestIndex, foot, half, cosLat, forward: true);

    // Reversed so the band runs in route order; MapLibre does not care, but a
    // line that doubles back on itself renders a visible kink at the join.
    return [...back.reversed, foot, ...fwd];
  }

  /// Follows the polyline from [foot] for [budget] metres and returns the
  /// vertices passed, ending with the point where the budget ran out.
  static List<List<double>> _walk(
    List<List<double>> route,
    int segIndex,
    List<double> foot,
    double budget,
    double cosLat, {
    required bool forward,
  }) {
    final out = <List<double>>[];
    var remaining = budget;
    var from = foot;
    var i = forward ? segIndex + 1 : segIndex;

    while (remaining > 0 && i >= 0 && i < route.length) {
      final to = route[i];
      final d = _metres(from[0], from[1], to[0], to[1], cosLat);
      if (d >= remaining) {
        final t = d == 0 ? 0.0 : remaining / d;
        out.add([
          from[0] + (to[0] - from[0]) * t,
          from[1] + (to[1] - from[1]) * t,
        ]);
        return out;
      }
      out.add(to);
      remaining -= d;
      from = to;
      i += forward ? 1 : -1;
    }
    return out;
  }

  /// Distance in metres from a point to a segment, plus where along the
  /// segment the nearest point falls (0 at the start, 1 at the end).
  ///
  /// Works in a local flat projection -- degrees scaled to metres, longitude
  /// corrected by cos(latitude). Over the tens of metres that matter here the
  /// error against a proper geodesic is millimetres, and it avoids a
  /// trigonometric call per segment across 450 segments per hazard.
  static (double, double) _pointToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
    double cosLat,
  ) {
    const m = 111320.0;
    final apx = (px - ax) * m * cosLat;
    final apy = (py - ay) * m;
    final abx = (bx - ax) * m * cosLat;
    final aby = (by - ay) * m;

    final len2 = abx * abx + aby * aby;
    final t = len2 == 0 ? 0.0 : ((apx * abx + apy * aby) / len2).clamp(0.0, 1.0);
    final dx = apx - abx * t;
    final dy = apy - aby * t;
    return (math.sqrt(dx * dx + dy * dy), t.toDouble());
  }

  static double _metres(
    double ax,
    double ay,
    double bx,
    double by,
    double cosLat,
  ) {
    const m = 111320.0;
    final dx = (bx - ax) * m * cosLat;
    final dy = (by - ay) * m;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Adds the two layers. Idempotent.
  ///
  /// [belowLayerId] should be the markers, so a band never covers the pin
  /// that explains it.
  static Future<void> addLayers(
    MapLibreMapController c, {
    String? belowLayerId,
  }) async {
    for (final id in [bandLayerId, glowLayerId]) {
      try {
        await c.removeLayer(id);
      } catch (_) {/* not present */}
    }
    try {
      await c.removeSource(sourceId);
    } catch (_) {/* not present */}

    await c.addGeoJsonSource(sourceId, geoJson(const []));

    // A soft wide glow under a solid band. One line at one width either looks
    // like a road casing (and gets mistaken for part of the basemap) or like
    // a highlighter stripe. Two reads as the road itself being lit up.
    await c.addLineLayer(
      sourceId,
      glowLayerId,
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineOpacity: 0.22,
        lineBlur: 6,
        lineCap: 'round',
        lineJoin: 'round',
        // Grows with zoom so it keeps covering the road as the road widens,
        // and stays visible when zoomed out where it does most of its work.
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 7.0,
          16, 20.0,
          19, 64.0,
        ],
      ),
      belowLayerId: belowLayerId,
      enableInteraction: false,
    );

    await c.addLineLayer(
      sourceId,
      bandLayerId,
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineOpacity: ['get', 'opacity'],
        lineCap: 'round',
        lineJoin: 'round',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 3.0,
          16, 9.0,
          19, 30.0,
        ],
      ),
      belowLayerId: belowLayerId,
      enableInteraction: false,
    );
  }

  static Future<void> update(
    MapLibreMapController c,
    List<HazardReport> reports,
  ) =>
      c.setGeoJsonSource(sourceId, geoJson(reports));

  static String _hex(HazardReport r) {
    final v = (r.color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '#$v';
  }
}
