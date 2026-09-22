import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/detection.dart';
import '../models/hazard_report.dart';
import 'app_config.dart';

/// Builds the style layers RoadScan adds on top of the base map, and the
/// GeoJSON the pin layers read.
///
/// Kept out of the widget so the visual encoding (what colour means what, what
/// fades, what pulses) can be reasoned about and changed in one place.
class MapLayers {
  MapLayers._();

  static const String buildingsLayerId = 'roadscan-3d-buildings';
  static const String mlBuildingsSourceId = 'roadscan-ml-buildings';
  static const String mlBuildingsLayerId = 'roadscan-ml-buildings-extrusion';
  static const String roadsLayerId = 'roadscan-road-contrast';
  static const String userSourceId = 'roadscan-user';
  static const String userPulseLayerId = 'roadscan-user-pulse';
  static const String userAccuracyLayerId = 'roadscan-user-accuracy';
  static const String userDotLayerId = 'roadscan-user-dot';
  static const String areaLabelSourceId = 'roadscan-area-labels';
  static const String areaLabelHaloLayerId = 'roadscan-area-labels-halo';
  static const String areaLabelLayerId = 'roadscan-area-labels-text';
  static const String maskSourceId = 'roadscan-bounds-mask';
  static const String maskFillLayerId = 'roadscan-bounds-mask-fill';
  static const String maskHatchLayerId = 'roadscan-bounds-mask-hatch';
  static const String maskEdgeLayerId = 'roadscan-bounds-edge';
  static const String pinSourceId = 'roadscan-pins';
  static const String pinGlowLayerId = 'roadscan-pins-glow';
  static const String pinCoreLayerId = 'roadscan-pins-core';
  static const String pinCountLayerId = 'roadscan-pins-count';

  /// The vector source name used by OpenMapTiles-schema styles, which is what
  /// OpenFreeMap serves. If you switch to a differently-schema'd tile provider,
  /// this and [_buildingSourceLayer] are what break.
  static const String _vectorSourceId = 'openmaptiles';
  static const String _buildingSourceLayer = 'building';
  static const String _transportSourceLayer = 'transportation';

  /// Redraws the road network on top of the dark basemap.
  ///
  /// OpenFreeMap's `dark` style paints roads only a shade lighter than its
  /// rgb(12,12,12) background. On the dense parts of the corridor that reads
  /// as moody; on a rural stretch like Kandholi the roads effectively vanish,
  /// which is unusable for an app whose entire job is telling you what is on
  /// the road ahead.
  ///
  /// Rather than switch to a washed-out slate basemap, this draws the
  /// `transportation` source-layer back over the top at a legible contrast.
  /// Width scales with zoom so the lines stay hairlines when zoomed out and
  /// become real roads up close, and motorway/trunk/primary are drawn heavier
  /// than residential so the hierarchy survives.
  ///
  /// Light mode does not need this -- `liberty` already has strong road
  /// contrast -- so the map screen only adds it for the dark theme.
  static Future<void> addRoadContrast(
    MapLibreMapController c, {
    bool neon = false,
  }) async {
    // Neon carries the launch screen's glowing-network look onto the map: a
    // wide, low-opacity halo under a bright core, same idea as the area cards.
    if (neon) {
      await c.addLineLayer(
        _vectorSourceId,
        '$roadsLayerId-glow',
        LineLayerProperties(
          lineColor: '#3FE0FF',
          lineWidth: [
            'interpolate',
            ['exponential', 1.5],
            ['zoom'],
            10, 2.0,
            14, 6.0,
            16, 11.0,
            19, 30.0,
          ],
          lineOpacity: 0.16,
          lineBlur: 6.0,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        sourceLayer: _transportSourceLayer,
        filter: ['!in', ['get', 'class'], 'path', 'footway', 'steps'],
        enableInteraction: false,
      );
    }

    await c.addLineLayer(
      _vectorSourceId,
      roadsLayerId,
      LineLayerProperties(
        lineColor: neon
            ? [
                'match',
                ['get', 'class'],
                'motorway', '#B8F4FF',
                'trunk', '#B8F4FF',
                'primary', '#8CEBFF',
                'secondary', '#5FE2FF',
                '#3FD4F5',
              ]
            : [
                'match',
                ['get', 'class'],
                'motorway', '#7FB2D9',
                'trunk', '#7FB2D9',
                'primary', '#6E9CC4',
                'secondary', '#5D86AB',
                '#4A6B88', // everything else: residential, service, track
              ],
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          10, 0.4,
          14, 1.4,
          16, 2.6,
          19, 8.0,
        ],
        lineOpacity: neon ? 0.95 : 0.85,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      sourceLayer: _transportSourceLayer,
      // Paths and steps are not driveable and would only add clutter.
      filter: [
        '!in',
        ['get', 'class'],
        'path',
        'footway',
        'steps',
      ],
      enableInteraction: false,
    );
  }

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

  // ---------------------------------------------------------------------------
  // Building footprints
  // ---------------------------------------------------------------------------

  /// Parsed once and kept for the life of the process.
  ///
  /// This asset is 3.2 MB of JSON covering 15,121 polygons, and every theme
  /// switch re-runs the whole style setup. Re-reading and re-decoding it on
  /// each swap was a visible stall -- the decode alone blocks the UI isolate.
  /// Holding the parsed map costs a few MB of heap and makes the second and
  /// subsequent swaps essentially free.
  static Map<String, dynamic>? _buildingsCache;

  static Future<Map<String, dynamic>> _buildingsGeoJson() async {
    final cached = _buildingsCache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/buildings.geojson');
    return _buildingsCache = json.decode(raw) as Map<String, dynamic>;
  }

  /// Extrudes the bundled Microsoft ML footprints.
  ///
  /// This is what makes the corridor look inhabited. OSM has 151 buildings
  /// inside the operating square -- measured, see tool/fetch_buildings.py --
  /// of which 8 are triangles and none carry a height, so the previous 3D
  /// view was a handful of identical 6 m wedges scattered over 81 km2. The
  /// bundled dataset has 15,121.
  ///
  /// Heights are ESTIMATED from footprint area by the bake script. They are a
  /// presentation heuristic, not survey data, and the report should say so.
  ///
  /// Replaces the OSM extrusion rather than sitting alongside it: the two
  /// datasets cover the same buildings, so drawing both would z-fight and
  /// double-render every wall in the few places OSM does have data.
  static Future<void> addMlBuildings(
    MapLibreMapController c, {
    required bool dark,
  }) async {
    // Hide the BASEMAP's own building layers first.
    //
    // These are the source of the stray triangular blocks: they are the
    // style's own rendering of the same sparse, badly-drawn OSM footprints,
    // and they sat underneath our layer rather than being replaced by it, so
    // the two datasets collided wherever OSM happened to have data.
    //
    // Layer ids verified against the live styles rather than assumed --
    // `liberty` ships a `building` fill AND a `building-3d` extrusion, while
    // `dark` ships only `building`. Hiding an id a style does not have throws,
    // hence the per-layer try.
    for (final id in const ['building', 'building-3d']) {
      try {
        await c.setLayerVisibility(id, false);
      } catch (_) {
        // Not present in this style; nothing to hide.
      }
    }

    await c.addGeoJsonSource(mlBuildingsSourceId, await _buildingsGeoJson());

    await c.addFillExtrusionLayer(
      mlBuildingsSourceId,
      mlBuildingsLayerId,
      FillExtrusionLayerProperties(
        // Two independent sources of variation, because height alone was not
        // enough to stop 15,000 blocks reading as one grey mass:
        //
        //   `h` gives the broad tiering -- sheds darker, tall blocks lighter,
        //       so the skyline has a legible hierarchy.
        //   `t` is a per-building tint baked into the asset (a hash of the
        //       footprint's own coordinates, so it is stable across launches
        //       and devices -- a building that changes shade between runs
        //       reads as a rendering glitch).
        //
        // Warm-grey rather than neutral: pure grey against a blue-tinted
        // basemap looks like untextured geometry, which is exactly the
        // complaint.
        fillExtrusionColor: [
          'interpolate',
          ['linear'],
          ['+', ['*', ['get', 'h'], 0.045], ['*', ['get', 't'], 0.55]],
          0.15, dark ? '#25384C' : '#CFD4DA',
          0.55, dark ? '#334C66' : '#C3C9D1',
          1.10, dark ? '#46617E' : '#B4BCC7',
        ],
        fillExtrusionHeight: ['get', 'h'],
        fillExtrusionBase: 0,
        fillExtrusionOpacity: 0.95,
        // The single biggest win for "they look like flat blocks": shades the
        // walls darker than the roof, so each building reads as a solid with
        // faces rather than a coloured silhouette.
        fillExtrusionVerticalGradient: true,
      ),
      // 15k polygons is a lot to extrude at corridor zoom, where each would be
      // a couple of pixels anyway. Below z15 they are not worth the GPU time.
      minzoom: 15.0,
      enableInteraction: false,
    );

    // Directional light. MapLibre's default is [1.15, 210, 30] anchored to the
    // VIEWPORT, which means the lighting swings around as you rotate the map
    // and every face ends up similarly lit -- part of why the blocks looked
    // flat. Anchoring to the MAP and dropping the polar angle to 55 puts the
    // sun low and fixed to the north-west, so walls facing away fall into
    // genuine shade and rotating the map moves the shadows convincingly.
    await c.setLight(LightProperties(
      anchor: 'map',
      position: const [1.4, 200, 55],
      color: dark ? '#9FC4E8' : '#FFF6E8',
      intensity: dark ? 0.32 : 0.45,
    ));
  }

  // ---------------------------------------------------------------------------
  // User position
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> userGeoJson(double? lat, double? lon) => {
        'type': 'FeatureCollection',
        'features': [
          if (lat != null && lon != null)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [lon, lat],
              },
              'properties': const {},
            },
        ],
      };

  /// Draws the user's own position.
  ///
  /// This replaces MapLibre's built-in location component, which had two
  /// problems here: its dot is a fixed small size that becomes almost
  /// invisible once you zoom out to see the whole corridor, and it is tied to
  /// the plugin's own tracking mode -- which had to be turned off, because
  /// with the camera clamped to the operating square it pinned the view to the
  /// boundary whenever the user stood outside it.
  ///
  /// Three stacked circles, drawn in this order:
  ///   pulse    a soft halo that GROWS as you zoom out, so the marker stays
  ///            findable at corridor scale instead of shrinking to a speck
  ///   accuracy a ring suggesting GPS uncertainty
  ///   dot      the position itself, white-ringed so it reads over any basemap
  static Future<void> addUserLayers(
    MapLibreMapController c, {
    required bool dark,
  }) async {
    await c.addGeoJsonSource(userSourceId, userGeoJson(null, null));

    await c.addCircleLayer(
      userSourceId,
      userPulseLayerId,
      const CircleLayerProperties(
        // Inverted with zoom on purpose: big when zoomed out (where you need
        // to find yourself), tight when zoomed in (where the dot is enough).
        circleRadius: [
          'interpolate',
          ['linear'],
          ['zoom'],
          12, 26.0,
          14, 20.0,
          16, 14.0,
          19, 10.0,
        ],
        circleColor: '#2E9CD6',
        circleOpacity: 0.20,
        circleBlur: 0.65,
      ),
      enableInteraction: false,
    );

    await c.addCircleLayer(
      userSourceId,
      userAccuracyLayerId,
      const CircleLayerProperties(
        circleRadius: [
          'interpolate',
          ['linear'],
          ['zoom'],
          12, 13.0,
          16, 9.0,
          19, 7.0,
        ],
        circleColor: '#2E9CD6',
        circleOpacity: 0.16,
        circleStrokeColor: '#4FB8ED',
        circleStrokeWidth: 1.0,
        circleStrokeOpacity: 0.45,
      ),
      enableInteraction: false,
    );

    await c.addCircleLayer(
      userSourceId,
      userDotLayerId,
      CircleLayerProperties(
        circleRadius: [
          'interpolate',
          ['linear'],
          ['zoom'],
          12, 7.0,
          16, 6.5,
          19, 6.0,
        ],
        circleColor: '#1E88E5',
        circleStrokeColor: dark ? '#FFFFFF' : '#FFFFFF',
        circleStrokeWidth: 2.5,
        circleStrokeOpacity: 1.0,
      ),
      enableInteraction: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Area labels
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _areaLabelGeoJson() => {
        'type': 'FeatureCollection',
        'features': [
          for (final a in AppConfig.areas)
            {
              'type': 'Feature',
              'id': a.id,
              'geometry': {
                'type': 'Point',
                'coordinates': [a.center.longitude, a.center.latitude],
              },
              'properties': {
                'id': a.id,
                'name': a.name.toUpperCase(),
              },
            },
        ],
      };

  /// Names the four areas directly on the map.
  ///
  /// Without these the only clue to which stretch you are looking at is the
  /// header, which names the area you *entered* from -- not the one you have
  /// since panned to. The corridor is 8 km of visually similar hill road, so
  /// that gap was real.
  ///
  /// Two layers rather than one: a dot beneath anchors the name to an actual
  /// point (a floating word over a road reads as a map label from the
  /// basemap, not as one of ours), and the text sits above it.
  ///
  /// Sizing runs BACKWARDS from the usual convention -- larger when zoomed
  /// out, smaller when zoomed in. Zoomed out these are the primary way to
  /// orient; zoomed in you are looking at individual potholes and the names
  /// should get out of the way.
  static Future<void> addAreaLabels(
    MapLibreMapController c, {
    required bool dark,
  }) async {
    await c.addGeoJsonSource(areaLabelSourceId, _areaLabelGeoJson());

    await c.addCircleLayer(
      areaLabelSourceId,
      areaLabelHaloLayerId,
      CircleLayerProperties(
        circleRadius: [
          'interpolate',
          ['linear'],
          ['zoom'],
          13, 5.0,
          16, 3.5,
          18, 2.5,
        ],
        circleColor: dark ? '#7FD4FF' : '#1B6CA8',
        circleOpacity: 0.9,
        circleStrokeColor: dark ? '#0A141F' : '#FFFFFF',
        circleStrokeWidth: 1.5,
        circleStrokeOpacity: 0.8,
      ),
      enableInteraction: false,
    );

    await c.addSymbolLayer(
      areaLabelSourceId,
      areaLabelLayerId,
      SymbolLayerProperties(
        textField: ['get', 'name'],
        textSize: [
          'interpolate',
          ['linear'],
          ['zoom'],
          13, 16.0,
          15, 14.0,
          17, 11.5,
        ],
        textColor: dark ? '#FFFFFF' : '#0E1A26',
        // A heavy halo in the background colour is what keeps these readable
        // over a busy road network without a filled plate behind them.
        textHaloColor: dark ? '#050D16' : '#FFFFFF',
        textHaloWidth: 2.0,
        textHaloBlur: 0.4,
        textLetterSpacing: 0.12,
        // Tight to its dot. A larger offset floated the name far enough from
        // the anchor that the two stopped reading as one thing.
        textOffset: [0, -0.7],
        textAnchor: 'bottom',
        // Collision padding around the glyph box. Note this does NOT keep a
        // label out from under the stats header -- MapLibre has no viewport
        // inset for symbol placement, so a name can still sit behind the
        // header when its area is near the top of the screen. That is normal
        // slippy-map behaviour (the label reappears as you pan) and the area
        // you actually opened is centred, so it is not the one occluded.
        textPadding: 2.0,
        // ONE font, not a fallback stack.
        //
        // MapLibre does not try a stack font-by-font: it joins the whole list
        // into a single glyph URL, so ['Noto Sans Bold', 'Noto Sans Regular']
        // requested `/fonts/Noto Sans Bold,Noto Sans Regular/0-255.pbf`, got a
        // 404, and the layer silently rendered nothing. Verified against
        // OpenFreeMap directly: 'Noto Sans Bold' and 'Noto Sans Regular' each
        // return 200 on their own, the combination does not.
        textFont: const ['Noto Sans Bold'],
        // These must always be visible -- they are the orientation aid, so
        // letting the collision engine drop them defeats the purpose.
        textAllowOverlap: true,
        textIgnorePlacement: true,
      ),
      enableInteraction: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Out-of-bounds mask
  // ---------------------------------------------------------------------------

  /// A world-covering polygon with the operating square punched out of it.
  ///
  /// GeoJSON polygons take an outer ring followed by hole rings, so this is
  /// literally "the whole world, minus the square". Painting the OUTSIDE is
  /// what makes the restriction feel deliberate: shading the inside would
  /// imply the corridor is the thing being excluded.
  ///
  /// The outer ring stops at +/-85 degrees rather than +/-90 because Web
  /// Mercator is undefined at the poles -- 90 would produce an infinite
  /// projected coordinate and the fill would simply not draw.
  static Map<String, dynamic> _maskGeoJson() {
    final sw = AppConfig.corridorSouthWest;
    final ne = AppConfig.corridorNorthEast;

    return {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': const {},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              // Outer ring: the world.
              const [
                [-180.0, -85.0],
                [180.0, -85.0],
                [180.0, 85.0],
                [-180.0, 85.0],
                [-180.0, -85.0],
              ],
              // Hole: the square the user is allowed inside.
              [
                [sw.longitude, sw.latitude],
                [ne.longitude, sw.latitude],
                [ne.longitude, ne.latitude],
                [sw.longitude, ne.latitude],
                [sw.longitude, sw.latitude],
              ],
            ],
          },
        },
      ],
    };
  }

  /// The square's own outline, drawn as a separate line feature.
  ///
  /// Kept separate from the mask polygon because a line layer on a polygon
  /// with a hole would stroke the world ring too, drawing a stray border
  /// along the antimeridian.
  static Map<String, dynamic> _edgeGeoJson() {
    final sw = AppConfig.corridorSouthWest;
    final ne = AppConfig.corridorNorthEast;
    return {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': const {},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [sw.longitude, sw.latitude],
              [ne.longitude, sw.latitude],
              [ne.longitude, ne.latitude],
              [sw.longitude, ne.latitude],
              [sw.longitude, sw.latitude],
            ],
          },
        },
      ],
    };
  }

  /// Masks everything outside the operating square and outlines it.
  ///
  /// [hatchImageId] is an optional registered image name (see
  /// [makeHatchImage]); when supplied, a diagonal-stripe pattern is drawn over
  /// the flat fill so the excluded region reads as "off limits" the way a
  /// hatched exclusion zone does on a plan, rather than merely as dimmed map.
  static Future<void> addBoundsMask(
    MapLibreMapController c, {
    String? hatchImageId,
  }) async {
    await c.addGeoJsonSource(maskSourceId, _maskGeoJson());
    await c.addGeoJsonSource('$maskSourceId-edge', _edgeGeoJson());

    await c.addFillLayer(
      maskSourceId,
      maskFillLayerId,
      const FillLayerProperties(
        fillColor: '#0B2A4A',
        // Heavy enough to kill legibility outside (that is the point) but not
        // opaque -- seeing a ghost of the surrounding roads tells the user
        // where they are relative to the corridor.
        fillOpacity: 0.82,
      ),
      enableInteraction: false,
    );

    if (hatchImageId != null) {
      await c.addFillLayer(
        maskSourceId,
        maskHatchLayerId,
        FillLayerProperties(
          fillPattern: hatchImageId,
          // Light touch. The hatch only needs to say "not here"; at higher
          // opacity it turned into a texture that competed with the real map
          // inside the square for attention.
          fillOpacity: 0.28,
        ),
        enableInteraction: false,
      );
    }

    await c.addLineLayer(
      '$maskSourceId-edge',
      maskEdgeLayerId,
      const LineLayerProperties(
        lineColor: '#4FB8ED',
        lineWidth: 1.8,
        lineOpacity: 0.55,
      ),
      enableInteraction: false,
    );
  }

  /// Builds a small diagonal-stripe tile to use as the mask's fill pattern.
  ///
  /// Generated at runtime rather than shipped as an asset: it is twelve lines
  /// of drawing code, scales to whatever DPR the device has, and avoids
  /// another binary in the repo.
  static Uint8List? _hatchCache;

  static Future<Uint8List?> makeHatchImage({int size = 16}) async {
    if (_hatchCache != null) return _hatchCache;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()
        ..color = const Color(0xFF6FC7F5).withValues(alpha: 0.45)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.square;

      // Two parallel diagonals, offset by the tile size, so the pattern is
      // seamless when repeated.
      final s = size.toDouble();
      canvas.drawLine(Offset(0, s), Offset(s, 0), paint);
      canvas.drawLine(Offset(-1, 1), Offset(1, -1), paint);
      canvas.drawLine(Offset(s - 1, s + 1), Offset(s + 1, s - 1), paint);

      final image = await recorder.endRecording().toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return _hatchCache = data?.buffer.asUint8List();
    } catch (e) {
      // A missing pattern is cosmetic -- the flat fill still masks the area.
      debugPrint('RoadScan: hatch pattern unavailable: $e');
      return null;
    }
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
