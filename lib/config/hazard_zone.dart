import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

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

  /// How far the band reaches along a MAIN road -- the corridor, and anything
  /// OSM classes as tertiary or above.
  ///
  /// Symmetric because a rider can arrive from either end, and both of them
  /// need the warning. A one-sided band only helps whoever happens to be
  /// coming from the direction it was drawn in.
  ///
  static const double halfLengthM = 50.0;

  /// And along a side street: a lane, a service road, a track. Shorter
  /// because they are slower and shorter, so fifty metres of warning would
  /// often be the whole street and would spill across several junctions.
  ///
  /// Applied PER ROAD as the traversal spreads, not per hazard. A pothole on
  /// the corridor reaches 50m up and down the corridor but only 30m along the
  /// side roads it meets, which is what those roads warrant.
  static const double minorReachM = 30.0;

  /// OSM highway classes that count as a main road.
  static const Set<String> _mainClasses = {
    'motorway',
    'trunk',
    'primary',
    'secondary',
    'tertiary',
    'motorway_link',
    'trunk_link',
    'primary_link',
    'secondary_link',
    'tertiary_link',
  };

  /// Every road, and an index of which roads meet at each point.
  ///
  /// The index is what makes the junction traversal possible: OSM ways that
  /// meet share an exact node coordinate, so keying on the rounded coordinate
  /// finds every arm of a junction without any geometric search.
  static List<List<List<double>>> _lines = const [];

  /// How far the band may travel along each road, by its OSM class. Parallel
  /// to [_lines].
  static List<double> _reach = const [];
  static final Map<String, List<(int, int)>> _nodes = {};

  static bool get hasRoutes => _lines.isNotEmpty;

  /// Rounded to about 1cm -- far finer than any two distinct junctions, far
  /// coarser than float noise between ways that share a node.
  static String _nodeKey(List<double> p) =>
      '${p[0].toStringAsFixed(7)},${p[1].toStringAsFixed(7)}';

  static List<(int, int)> _touching(String key) => _nodes[key] ?? const [];

  static void _index() {
    _nodes.clear();
    for (var li = 0; li < _lines.length; li++) {
      final line = _lines[li];
      for (var vi = 0; vi < line.length; vi++) {
        (_nodes[_nodeKey(line[vi])] ??= <(int, int)>[]).add((li, vi));
      }
    }
  }

  /// Takes assets/roads.geojson -- the drivable OSM network for the whole
  /// operating square -- and keeps its line geometry.
  ///
  /// This replaced two earlier sources, both of which failed in ways worth
  /// recording. The corridor alone covered the main route only, so a hazard
  /// on any side street found no road in range and got no band, which is most
  /// reports. The launch screen's card artwork covered side streets but its
  /// coordinates are normalised fractions running to 2.99, because the cards
  /// clip whatever overflows; extrapolated into real coordinates those parts
  /// landed hundreds of metres from any road, drawing bands across open
  /// ground and at the wrong angle to the road they meant to trace.
  ///
  /// See tool/fetch_roads.py. 2186 ways, so the snap works anywhere a report
  /// can be filed rather than near four sampled areas.
  static void loadRoadNetwork(Map<String, dynamic> geojson) {
    final out = <List<List<double>>>[];
    final reach = <double>[];
    final features = geojson['features'];
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
        final props = f['properties'];
        final cls = props is Map ? props['c'] : null;
        reach.add(
          _mainClasses.contains(cls) ? halfLengthM : minorReachM,
        );
      }
    }
    _lines = out;
    _reach = reach;
    _index();
  }

  static Map<String, dynamic> geoJson(List<HazardReport> reports) {
    final features = <Map<String, dynamic>>[];

    for (final r in reports) {
      // A pin already voted fixed should not still be closing a lane.
      if (r.isFixed) continue;
      final parts = _reachFrom(r);
      if (parts.isEmpty) continue;
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
        // MultiLineString: one feature carrying every arm reached, so the
        // whole zone stays a single feature with one colour and one opacity.
        'geometry': {'type': 'MultiLineString', 'coordinates': parts},
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// Every stretch of road within [halfLengthM] of [r], following the network
  /// outward in all directions.
  ///
  /// Not a line along one road: a flood fill across the road graph. At a
  /// junction the danger is on every arm, because riders arrive on all of
  /// them, and the earlier version -- walk one road, and at its end pick the
  /// straightest continuation -- covered exactly two of the three arms at the
  /// UPES junction and silently chose which. That choice was a heuristic
  /// standing in for the real answer, which is simply "everything within 50m
  /// by road".
  ///
  /// This also removes the special cases it needed. There is no forward and
  /// backward, no turn threshold, no hop limit, and no difference between a
  /// hazard mid-road and one sitting on a junction. It is the same traversal
  /// either way, so it generalises to anywhere on the map.
  ///
  /// Dijkstra rather than a plain queue because two routes can reach the same
  /// place -- around a block, say -- and the band should extend to whichever
  /// is genuinely nearer by road.
  static List<List<List<double>>> _reachFrom(HazardReport r) {
    if (_lines.isEmpty) return const [];

    final cosLat = math.cos(r.lat * math.pi / 180.0);

    // Snap to the nearest segment of any road.
    var bestLine = -1;
    var bestIndex = 0;
    var bestT = 0.0;
    var bestDist = double.infinity;

    for (var li = 0; li < _lines.length; li++) {
      final line = _lines[li];
      for (var i = 0; i < line.length - 1; i++) {
        final (d, t) = _pointToSegment(
          r.lon,
          r.lat,
          line[i][0],
          line[i][1],
          line[i + 1][0],
          line[i + 1][1],
          cosLat,
        );
        if (d < bestDist) {
          bestDist = d;
          bestLine = li;
          bestIndex = i;
          bestT = t;
        }
      }
    }

    // No road near enough. Nothing is drawn, deliberately: a band over open
    // ground claims a hazard is on a road that is not there.
    if (bestLine < 0 || bestDist > maxSnapM) return const [];

    final line = _lines[bestLine];
    final a = line[bestIndex];
    final b = line[bestIndex + 1];
    final foot = [
      a[0] + (b[0] - a[0]) * bestT,
      a[1] + (b[1] - a[1]) * bestT,
    ];

    final parts = <List<List<double>>>[];

    // Seed: the two halves of the segment the hazard sits on. Everything
    // after this is graph traversal from its two endpoints.
    final best = <String, double>{};
    final queue = <({String key, List<double> at, double cost})>[];

    final footReach = _reach[bestLine];

    void seed(List<double> vertex) {
      final d = _metres(foot[0], foot[1], vertex[0], vertex[1], cosLat);
      if (d >= footReach) {
        parts.add([foot, _towards(foot, vertex, footReach, cosLat)]);
        return;
      }
      parts.add([foot, vertex]);
      final k = _nodeKey(vertex);
      if (d < (best[k] ?? double.infinity)) {
        best[k] = d;
        queue.add((key: k, at: vertex, cost: d));
      }
    }

    seed(a);
    seed(b);

    while (queue.isNotEmpty) {
      // Smallest cost first. A linear scan is fine: the frontier inside a 50m
      // radius is a handful of nodes, and a heap would cost more to maintain
      // than it saves.
      var pick = 0;
      for (var i = 1; i < queue.length; i++) {
        if (queue[i].cost < queue[pick].cost) pick = i;
      }
      final node = queue.removeAt(pick);
      if (node.cost > (best[node.key] ?? double.infinity)) continue;

      for (final (li, vi) in _touching(node.key)) {
        final l = _lines[li];
        for (final ni in [vi - 1, vi + 1]) {
          if (ni < 0 || ni >= l.length) continue;
          final next = l[ni];
          final step = _metres(
            node.at[0],
            node.at[1],
            next[0],
            next[1],
            cosLat,
          );
          final total = node.cost + step;

          // Each road carries its own limit, so a band spreading from a main
          // road onto a lane stops at the lane's shorter reach.
          final limit = _reach[li];
          if (total >= limit) {
            final left = limit - node.cost;
            if (left > 0.5) {
              parts.add([
                node.at,
                _towards(node.at, next, left, cosLat),
              ]);
            }
            continue;
          }

          final k = _nodeKey(next);
          if (total >= (best[k] ?? double.infinity)) continue;
          best[k] = total;
          parts.add([node.at, next]);
          queue.add((key: k, at: next, cost: total));
        }
      }
    }

    return parts;
  }

  /// The point [metres] along the way from [from] to [to].
  static List<double> _towards(
    List<double> from,
    List<double> to,
    double metres,
    double cosLat,
  ) {
    final d = _metres(from[0], from[1], to[0], to[1], cosLat);
    if (d <= 0) return [to[0], to[1]];
    final f = (metres / d).clamp(0.0, 1.0);
    return [
      from[0] + (to[0] - from[0]) * f,
      from[1] + (to[1] - from[1]) * f,
    ];
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
