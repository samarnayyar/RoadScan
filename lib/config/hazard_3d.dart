import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/detection.dart' show SeverityClass;
import '../models/hazard_report.dart';

/// Builds the 3D crater drawn at each hazard.
///
/// Why a crater has to be built rather than modelled
/// -------------------------------------------------
/// MapLibre cannot draw a hole. `fill-extrusion-height` is validated to be
/// >= 0, so nothing descends below the road surface, and MapLibre Native on
/// Android has no glTF or custom-3D-layer route either -- those exist only in
/// GL JS via three.js. A literal depression is unavailable at any level of
/// effort.
///
/// What IS available: an extruded polygon WITH A HOLE renders walls on both
/// its outer and inner boundary. Stack concentric annuli whose heights step
/// DOWN toward the centre and the result is a funnel -- a raised rim, two
/// terraces falling inward, and a floor at road level. With the camera
/// pitched, which this map always is, the eye reads the floor as sitting
/// below the rim, because it does: by the rim's full height.
///
/// The depth is therefore real relative geometry, not a texture trick. It is
/// built upward from the road and perceived downward from the rim.
///
/// Honest about scale
/// ------------------
/// The crater is a MARKER and is deliberately larger than the damage. A real
/// 0.4 m pothole at z18 is about eight pixels across; drawn true-size it is
/// invisible, which defeats the point of putting it on a map. So the rim is
/// sized generously and floored at a minimum, while the PHOTO laid inside it
/// uses the estimated true footprint. The marker says "here, and roughly this
/// bad"; the photo says "this is what it actually is".
class Hazard3d {
  Hazard3d._();

  static const String sourceId = 'roadscan-crater';
  static const String rimLayerId = 'roadscan-crater-rim';
  static const String wallLayerId = 'roadscan-crater-wall';
  static const String floorLayerId = 'roadscan-crater-floor';

  /// Below this a crater is a smudge and every ring is wasted geometry.
  ///
  /// Set against the SMALLEST crater worth drawing. Below this even a
  /// generously-drawn pothole is a couple of pixels, and the marker is doing
  /// that job better.
  static const double minZoom = 18.0;

  /// Smallest crater drawn, in metres.
  ///
  /// Reports filed before the footprint estimator existed carry no size at
  /// all, and the estimator declines geometry it cannot trust. Rather than
  /// invent a number for those, they get the smallest plausible pothole and
  /// the card says the size is unknown.
  static const double fallbackDiameterM = 0.5;

  /// How much the DEPTH is exaggerated, and nothing else.
  ///
  /// A real pothole is a few centimetres deep: at true scale the walls of a
  /// 0.9 m pothole are under two pixels even with the camera on top of it,
  /// and the crater would render as a flat stain. So the vertical axis is
  /// stretched, the way a terrain visualisation does it. Everything the app
  /// REPORTS as a measurement stays unexaggerated.
  static const double depthExaggeration = 3.0;

  /// Crater depth as a fraction of its own SHORT axis, by severity.
  ///
  /// Ratios rather than absolute depths, because a 2 m crater and a 0.4 m one
  /// are not the same hole at different distances -- a severe pothole is
  /// deeper RELATIVE to its width. These are before [depthExaggeration].
  ///
  /// The ceiling on them is occlusion, and it is worth stating because it is
  /// not obvious. The camera looks down at 50 degrees from vertical, so a ray
  /// grazing the near rim travels about 1.19 depths horizontally before it
  /// reaches the floor. Past roughly a third of the width, the near wall
  /// swallows the floor and the crater reads as a solid tower instead of a
  /// pit.
  static double depthFractionFor(SeverityClass s) => switch (s) {
        SeverityClass.low => 0.06,
        SeverityClass.medium => 0.09,
        SeverityClass.high => 0.12,
        SeverityClass.critical => 0.16,
      };

  /// Floor width as a fraction of the opening.
  static const double floorFraction = 0.44;

  /// Smallest the crater is drawn on screen, in logical pixels.
  ///
  /// Real size alone put the crater out of reach: a 0.9 m pothole is seven
  /// pixels at z19 and needs z21.5 to be worth looking at, which meant the 3D
  /// existed only if you flew all the way down to it. Below this threshold
  /// the crater is scaled up so it stays visible earlier.
  static const double minScreenPx = 34.0;

  /// Ceiling on that scaling.
  ///
  /// This is the number that stops the honest fix becoming the old lie. The
  /// crater grew to nine metres when it was sized purely for the screen --
  /// wider than the road, absurd beside the buildings. Capped at twice the
  /// real footprint, a 0.9 m pothole is drawn at most 1.8 m across: still
  /// plainly a marker, but the same ORDER as the damage, and the card always
  /// states the real measurement.
  static const double maxExaggeration = 2.0;

  /// Ground metres covered by one logical pixel at [zoom] and [lat].
  ///
  /// MapLibre uses 512 px tiles, so the world is 512 px wide at z0 and the
  /// equatorial resolution is 40075017 / 512 = 78271.5 m/px. The cosine term
  /// is the Mercator correction -- at Dehradun's latitude a pixel covers
  /// about 14% less ground than at the equator.
  static double metresPerPixel(double lat, double zoom) =>
      78271.516964 * math.cos(lat * math.pi / 180.0) / math.pow(2.0, zoom);

  /// The crater's ground size for [r] at [zoom]: (east-west, north-south).
  ///
  /// The ASPECT RATIO is always the real one the estimator derived from the
  /// photo, so a wide shallow scrape and a narrow deep hole are different
  /// shapes, not the same circle at different sizes. Only the overall scale
  /// is nudged, and only up, and only to [maxExaggeration].
  static (double, double) openingFor(HazardReport r, double zoom) {
    final (w, l) = r.hasFootprint
        ? (r.widthM!, r.lengthM!)
        : (fallbackDiameterM, fallbackDiameterM);

    final longest = math.max(w, l);
    if (longest <= 0) return (fallbackDiameterM, fallbackDiameterM);

    final wanted = minScreenPx * metresPerPixel(r.lat, zoom);
    final k = (wanted / longest).clamp(1.0, maxExaggeration);
    return (w * k, l * k);
  }

  /// GeoJSON for every crater: three nested annuli plus a floor disc.
  ///
  /// One source for all hazards rather than one per pin. Three layers filter
  /// it by `tier`, so the whole set redraws with a single setGeoJsonSource
  /// call when pins change. A layer pair per hazard would mean dozens of
  /// platform-channel round trips on every refresh.
  static Map<String, dynamic> geoJson(
    List<HazardReport> reports, {
    required double zoom,
  }) {
    final features = <Map<String, dynamic>>[];

    for (final r in reports) {
      final (wM, lM) = openingFor(r, zoom);
      // Depth off the SHORT axis: a 2 m x 0.3 m crack is shallow, and keying
      // depth to the long axis would make it a trench.
      final h = math.min(wM, lM) *
          depthFractionFor(r.severity) *
          depthExaggeration;
      final colour = _hex(r.color);

      // [outerFraction, innerFraction, heightFraction]. Three terraces falling
      // from the lip to the floor: each is an annulus, and an extruded annulus
      // has walls on BOTH its boundaries, which is where the visible steps
      // come from. The floor itself is height 0 -- road level, a full depth
      // below the lip.
      const steps = <List<double>>[
        [1.00, 0.80, 1.00],
        [0.80, 0.62, 0.55],
        [0.62, floorFraction, 0.22],
      ];

      for (var i = 0; i < steps.length; i++) {
        final st = steps[i];
        features.add({
          'type': 'Feature',
          // Top-level id, not just a property: onFeatureTapped reports the
          // feature's id member, and the rim is a tap target.
          'id': r.id,
          'properties': {
            'id': r.id,
            'tier': i == 0 ? 'rim' : 'wall',
            'height': h * st[2],
            // Each terrace darker than the one above, so the funnel reads as
            // receding into shadow even from near-overhead, where the walls
            // themselves are barely visible.
            'color': _darken(colour, i * 0.22),
          },
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              _ring(r.lat, r.lon, wM * st[0] / 2, lM * st[0] / 2, r.id, i),
              _ring(r.lat, r.lon, wM * st[1] / 2, lM * st[1] / 2, r.id, i)
                  .reversed
                  .toList(),
            ],
          },
        });
      }

      features.add({
        'type': 'Feature',
        'id': r.id,
        'properties': {
          'id': r.id,
          'tier': 'floor',
          'height': 0.0,
          'color': _darken(colour, 0.68),
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            _ring(r.lat, r.lon, wM * floorFraction / 2,
                lM * floorFraction / 2, r.id, steps.length - 1),
          ],
        },
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// Adds the three layers. Idempotent.
  static Future<void> addLayers(MapLibreMapController c) async {
    for (final id in [floorLayerId, wallLayerId, rimLayerId]) {
      try {
        await c.removeLayer(id);
      } catch (_) {/* not present */}
    }
    try {
      await c.removeSource(sourceId);
    } catch (_) {/* not present */}

    // Explicit source options, not addGeoJsonSource's defaults, and the
    // crater does not render at all without them.
    //
    // A GeoJSON source is tiled through geojson-vt, which indexes only to
    // `maxzoom` (default 18) and overzooms beyond it, applying Douglas-Peucker
    // simplification at `tolerance` (default 0.375 px) in tile space. A crater
    // is now drawn at its real size -- under a metre across -- which at z18 is
    // a fraction of one pixel. The simplifier collapsed every ring to nothing,
    // so the layers were perfectly correct and perfectly empty at every zoom.
    //
    // maxzoom 24 indexes down to where the crater is actually looked at, and
    // tolerance 0 keeps all 64 vertices per ring so the outline stays smooth
    // rather than turning into a visible dodecagon.
    await c.addSource(
      sourceId,
      GeojsonSourceProperties(
        data: geoJson(const [], zoom: minZoom),
        maxzoom: 24,
        tolerance: 0,
        buffer: 0,
      ),
    );

    // Floor first, so the walls draw over its edge.
    await c.addFillLayer(
      sourceId,
      floorLayerId,
      const FillLayerProperties(
        fillColor: ['get', 'color'],
        fillOpacity: 0.95,
      ),
      filter: const ['==', 'tier', 'floor'],
      minzoom: minZoom,
      enableInteraction: false,
    );

    await c.addFillExtrusionLayer(
      sourceId,
      wallLayerId,
      const FillExtrusionLayerProperties(
        fillExtrusionColor: ['get', 'color'],
        fillExtrusionHeight: ['get', 'height'],
        fillExtrusionBase: 0,
        fillExtrusionOpacity: 0.96,
        // Shades each wall darker toward its foot, which is what makes a
        // terrace read as a step down rather than a flat coloured band.
        fillExtrusionVerticalGradient: true,
      ),
      filter: const ['==', 'tier', 'wall'],
      minzoom: minZoom,
      enableInteraction: false,
    );

    await c.addFillExtrusionLayer(
      sourceId,
      rimLayerId,
      const FillExtrusionLayerProperties(
        fillExtrusionColor: ['get', 'color'],
        fillExtrusionHeight: ['get', 'height'],
        fillExtrusionBase: 0,
        fillExtrusionOpacity: 0.98,
        fillExtrusionVerticalGradient: true,
      ),
      filter: const ['==', 'tier', 'rim'],
      minzoom: minZoom,
      // The rim IS the tap target at these zooms. It is roughly seventy pixels
      // across where the pin marker is twenty, and by then the pin has faded
      // out so the photo on the crater floor is visible -- so without this the
      // hazard would get harder to tap the closer you looked at it.
      enableInteraction: true,
    );
  }

  /// Pushes new geometry without touching the layers.
  static Future<void> update(
    MapLibreMapController c,
    List<HazardReport> reports, {
    required double zoom,
  }) =>
      c.setGeoJsonSource(sourceId, geoJson(reports, zoom: zoom));

  /// A closed ring of [lon, lat] around a point, elliptical and roughened.
  ///
  /// Two things make this not a circle.
  ///
  /// The ELLIPSE is real: [halfW] and [halfL] are the photo-derived footprint,
  /// so a crater drawn from a wide shallow scrape is wide and shallow on the
  /// map. The RAGGEDNESS is not -- it is a deterministic wobble seeded from
  /// the report id, and it is there because a perfect ellipse reads as a
  /// graphic stamped on the road rather than as broken asphalt. It is honest
  /// decoration, not information: it does not claim this is the outline the
  /// pothole actually has. Recovering the true outline needs a segmentation
  /// mask, which this build's detector does not produce.
  ///
  /// Seeded from the id so one hazard keeps the same shape across redraws,
  /// zoom changes and devices. A random wobble would shimmer on every pan.
  ///
  /// 64 segments, and longitude divided by cos(latitude) so a metre east is
  /// the same as a metre north.
  static List<List<double>> _ring(
    double lat,
    double lon,
    double halfW,
    double halfL,
    String seedKey,
    int tier, {
    int segments = 64,
  }) {
    const mPerDegLat = 111320.0;
    final cosLat = math.cos(lat * math.pi / 180.0);
    final safeCos = cosLat.abs() < 0.01 ? 0.01 : cosLat;

    // Inner terraces wobble less, the way a real hole's profile smooths out
    // toward the bottom.
    final amplitude = 0.16 / (1 + tier);
    final seed = seedKey.hashCode;

    final out = <List<double>>[];
    for (var i = 0; i <= segments; i++) {
      final t = 2 * math.pi * i / segments;
      // Three harmonics: one lobe-scale, two finer. Enough to break the
      // silhouette without turning it into a starburst.
      final n = 0.60 * math.sin(3 * t + _phase(seed, 1)) +
          0.28 * math.sin(7 * t + _phase(seed, 2)) +
          0.12 * math.sin(11 * t + _phase(seed, 3));
      final k = 1.0 + amplitude * n;

      final dLat = (halfL * k) / mPerDegLat;
      final dLon = (halfW * k) / (mPerDegLat * safeCos);
      out.add([lon + dLon * math.cos(t), lat + dLat * math.sin(t)]);
    }
    // Close exactly, so no sliver seam where the wobble does not quite meet.
    out[out.length - 1] = [out.first[0], out.first[1]];
    return out;
  }

  /// A stable angle in [0, 2pi) from a seed and a harmonic index.
  static double _phase(int seed, int k) {
    final v = (seed ^ (k * 0x9E3779B9)) & 0x7FFFFFFF;
    return (v % 6283) / 1000.0;
  }

  static String _hex(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    final v = (r << 16) | (g << 8) | b;
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  /// Mixes [hex] toward black by [amount] (0..1).
  static String _darken(String hex, double amount) {
    if (amount <= 0) return hex;
    final v = int.parse(hex.substring(1), radix: 16);
    final k = 1 - amount.clamp(0.0, 1.0);
    final r = (((v >> 16) & 0xFF) * k).round();
    final g = (((v >> 8) & 0xFF) * k).round();
    final b = ((v & 0xFF) * k).round();
    final out = (r << 16) | (g << 8) | b;
    return '#${out.toRadixString(16).padLeft(6, '0')}';
  }
}
