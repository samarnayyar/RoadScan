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
  static const String waterSourceId = 'roadscan-water';
  static const String waterBodyLayerId = 'roadscan-water-body';
  static const String waterGlowLayerId = 'roadscan-water-glow';
  static const String waterCaseLayerId = 'roadscan-water-case';
  static const String waterLineLayerId = 'roadscan-water-line';
  static const String waterLabelLayerId = 'roadscan-water-label';
  static const String corridorSourceId = 'roadscan-corridor';
  static const String corridorGlowLayerId = 'roadscan-corridor-glow';
  static const String corridorCaseLayerId = 'roadscan-corridor-case';
  static const String corridorCoreLayerId = 'roadscan-corridor-core';
  static const String corridorSpurGlowLayerId = 'roadscan-corridor-spur-glow';
  static const String corridorSpurLayerId = 'roadscan-corridor-spur';

  /// The vector source name used by OpenMapTiles-schema styles, which is what
  /// OpenFreeMap serves. If you switch to a differently-schema'd tile provider,
  /// this and [_buildingSourceLayer] are what break.
  /// Zoom from which the 3D buildings draw.
  ///
  /// Lowered from 15.0: the skyline vanished the moment you pulled back even
  /// slightly, so the map flipped between "city" and "empty valley" over a
  /// single pinch. 14.0 keeps the built-up areas readable across a much wider
  /// view.
  ///
  /// Not lowered further on purpose. This is 15,121 extruded polygons, and
  /// each zoom level out roughly quadruples the ground area on screen -- so
  /// the count actually drawn climbs fast, and every one of them is a
  /// sub-pixel smudge well before z13. 14.0 is where the visual gain stops
  /// paying for the fill rate.
  static const double buildingsMinZoom = 14.0;

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
    await _dropLayer(c, '$roadsLayerId-glow');
    await _dropLayer(c, roadsLayerId);

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
            // Deliberately modest. Two reasons, one visual and one
            // performance:
            //   * at 14px the halo was wider than the streets it traced, so
            //     the network read as thick tubes and made the map itself
            //     look smaller;
            //   * a blurred line is a separate, fill-rate-heavy pass, and
            //     cost scales with width * blur. The wide version was the
            //     main source of the frame drop.
            12, 3.0,
            14, 5.0,
            16, 7.5,
            19, 16.0,
          ],
          lineOpacity: 0.20,
          // Halved from 6.0. Blur radius is the expensive half of this layer
          // and the glow still reads at 3.
          lineBlur: 3.0,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        sourceLayer: _transportSourceLayer,
        // Legacy filter form: the property is a bare string, NOT ['get',...].
        // The expression form is silently rejected by the Android binding with
        // "filter property must be a string", leaving the layer unfiltered.
        filter: const ['!in', 'class', 'path', 'footway', 'steps'],
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
          // 0.4px at z10 was a hairline that disappeared entirely on a
          // zoomed-out view -- the roads only became visible past about z14.
          // Since the camera now opens at minZoom (the whole corridor), the
          // low end has to carry real weight. Settled around 3-4px at working
          // zooms, which is legible without the roads dominating the map.
          12, 1.4,
          14, 2.2,
          16, 3.4,
          19, 7.0,
        ],
        lineOpacity: neon ? 0.95 : 0.85,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      sourceLayer: _transportSourceLayer,
      // Paths and steps are not driveable and would only add clutter.
      // Legacy filter form -- see the note on the glow layer above.
      filter: const ['!in', 'class', 'path', 'footway', 'steps'],
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

  /// Removes a layer if present. MapLibre throws when adding a layer id that
  /// already exists, and the style-loaded callback can fire more than once
  /// per style, so every add in here is preceded by one of these.
  static Future<void> _dropLayer(
      MapLibreMapController c, String id) async {
    try {
      await c.removeLayer(id);
    } catch (_) {
      // Not present. Nothing to remove.
    }
  }

  /// The first of [candidates] that exists in the current style, or null.
  ///
  /// Used to pick a `belowLayerId`: MapLibre throws when asked to insert
  /// below a layer that is not there, which would take down the whole add
  /// rather than just losing the ordering. Every layer this anchors to is
  /// added inside its own try block and can legitimately be absent, so the
  /// null fallback (a plain add, on top) has to stay a valid outcome --
  /// being mis-ordered beats not being drawn.
  static Future<String?> _firstExisting(
    MapLibreMapController c,
    List<String> candidates,
  ) async {
    try {
      final ids = await c.getLayerIds();
      for (final id in candidates) {
        if (ids.contains(id)) return id;
      }
    } catch (_) {
      // Fall through to a plain add.
    }
    return null;
  }

  static Future<void> _dropSource(
      MapLibreMapController c, String id) async {
    try {
      await c.removeSource(id);
    } catch (_) {
      // Not present, or still referenced by a layer we already dropped.
    }
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
    // REMOVED, not hidden.
    //
    // setLayerVisibility did not reliably stick here -- the basemap's stray
    // wedge-shaped buildings kept reappearing after a style swap even though
    // the call reported no error. Deleting the layers outright is
    // unambiguous, and there is no case where this app wants them: they are
    // the same 151 sparse, badly-drawn OSM footprints (8 of them literal
    // triangles) that the bundled Microsoft dataset exists to replace.
    for (final id in const ['building', 'building-3d']) {
      await _dropLayer(c, id);
    }

    // Read the asset BEFORE touching the map. If this throws, the bake really
    // is missing and the caller should fall back; anything that throws after
    // this point is a map-side problem and must not trigger a fallback.
    final geo = await _buildingsGeoJson();

    await _dropLayer(c, mlBuildingsLayerId);
    await _dropSource(c, mlBuildingsSourceId);
    await c.addGeoJsonSource(mlBuildingsSourceId, geo);

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
      // a couple of pixels anyway. See buildingsMinZoom for where the line is
      // drawn and why.
      minzoom: buildingsMinZoom,
      // Slot UNDER the hazard pins rather than on top of the style.
      //
      // This layer is added lazily, once the camera is close enough to want
      // it, which is long after _installLayers has finished. A plain add puts
      // it at the top of the stack, where the extrusions swallow everything
      // that matters: the four area names, the hazard pins, and the user's
      // own position marker -- and they do it at exactly the zooms where
      // buildings exist, which is where a rider actually reads the map.
      //
      // Anchoring to the pin glow (the first layer added above the mask)
      // keeps the buildings above the roads, so the 3D still reads correctly
      // when the camera is pitched, while leaving pins, position and place
      // names clear above them.
      belowLayerId: await _firstExisting(c, const [
        pinGlowLayerId,
        areaLabelLayerId,
      ]),
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
  // Water and the main corridor
  //
  // Both are drawn in FIXED colours that ignore the theme.
  //
  // Everything else on this map recolours per theme, but these two are
  // orientation landmarks: the river tells you which side of the valley you
  // are on, and the corridor is the one road that links all four areas. If
  // they changed appearance between dark, light and neon you would have to
  // re-learn the map every time the theme flipped, which defeats the point of
  // marking them at all. Amber and blue were picked because they stay legible
  // against the near-black dark basemap, the pale liberty basemap AND the
  // cyan-heavy neon palette, and because neither collides with the hazard pin
  // severity ramp (yellow/orange/red) at the sizes these are drawn.
  // ---------------------------------------------------------------------------

  static Map<String, dynamic>? _waterCache;
  static Map<String, dynamic>? _corridorCache;

  static Future<Map<String, dynamic>> _waterGeoJson() async {
    final cached = _waterCache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/rivers.geojson');
    return _waterCache = json.decode(raw) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> _corridorGeoJson() async {
    final cached = _corridorCache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/corridor.geojson');
    return _corridorCache = json.decode(raw) as Map<String, dynamic>;
  }

  /// A zoom ramp whose output is scaled by the feature's `r` rank, so a named
  /// river outweighs a drainage stream. Without the hierarchy, "make the water
  /// evident" just turns the whole valley blue.
  ///
  /// The rank has to be applied INSIDE the interpolate outputs, not by
  /// multiplying the whole ramp: MapLibre rejects `['*', ['interpolate',
  /// ['zoom'], ...], factor]` with `"zoom" expression may only be used as
  /// input to a top-level "step" or "interpolate" expression`, and the layer
  /// then renders at its default width with only a JNI log line to show for
  /// it. Verified on device.
  ///
  /// r: 2 = river, 1 = canal, 0 = stream.
  static List<Object> _rankedWidth(double z12, double z16, double z19) {
    List<Object> at(double w) => [
          'match',
          ['get', 'r'],
          2, w,
          1, w * 0.62,
          w * 0.40,
        ];
    return [
      'interpolate',
      ['exponential', 1.5],
      ['zoom'],
      12, at(z12),
      16, at(z16),
      19, at(z19),
    ];
  }

  /// Draws the rivers, streams and water bodies baked by
  /// tool/fetch_overlays.py.
  ///
  /// The basemap does carry water, but both OpenFreeMap styles paint it as a
  /// barely-there fill -- on the dark style the Tons through Nanda Ki Chowki
  /// is a slightly different black, and on a phone in daylight it is simply
  /// not there. This redraws it as a glowing ribbon so the watercourse reads
  /// as a continuous thing you can follow, which is how a river actually works
  /// as a landmark.
  ///
  /// Three passes, widest first: a blurred halo, the channel itself, then the
  /// name repeated along the line for the named rivers.
  static Future<void> addWater(MapLibreMapController c) async {
    // Read the asset before touching the map -- same reasoning as
    // addMlBuildings: a missing bake should fail before any layer is added.
    final geo = await _waterGeoJson();

    for (final id in const [
      waterLabelLayerId,
      waterLineLayerId,
      waterCaseLayerId,
      waterGlowLayerId,
      waterBodyLayerId,
    ]) {
      await _dropLayer(c, id);
    }
    await _dropSource(c, waterSourceId);
    await c.addGeoJsonSource(waterSourceId, geo);

    // Lakes and ponds. Legacy filter form -- bare property name, not
    // ['get', 'k'] -- see the note on addRoadContrast.
    await c.addFillLayer(
      waterSourceId,
      waterBodyLayerId,
      const FillLayerProperties(
        fillColor: '#1668D8',
        fillOpacity: 0.62,
        fillOutlineColor: '#7FD0FF',
      ),
      filter: const ['==', 'k', 'water'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      waterSourceId,
      waterGlowLayerId,
      LineLayerProperties(
        lineColor: '#1F6FD0',
        lineWidth: _rankedWidth(5.4, 15.0, 30.0),
        // Kept low and modestly blurred. A blurred line is a fill-rate-heavy
        // pass and the cost scales with width * blur -- the same trap that
        // caused the neon road frame drop, so this stays well under the
        // widths used there.
        lineOpacity: 0.26,
        lineBlur: 3.0,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['!=', 'k', 'water'],
      enableInteraction: false,
    );

    // Dark casing under the channel.
    //
    // Without it the river is legible in dark and light but DISAPPEARS in
    // neon, where the road network is drawn in bright cyan and the water is
    // just one more blue line in the mesh. A near-black outline separates the
    // channel from whatever it crosses in all three themes: from the cyan
    // roads in neon, from the pale ground in light, and from the building
    // extrusions in dark.
    await c.addLineLayer(
      waterSourceId,
      waterCaseLayerId,
      LineLayerProperties(
        lineColor: '#02121F',
        lineWidth: _rankedWidth(3.6, 9.8, 20.0),
        lineOpacity: 0.95,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['!=', 'k', 'water'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      waterSourceId,
      waterLineLayerId,
      LineLayerProperties(
        // Deep blue, NOT the azure this started as.
        //
        // In neon the road network is drawn in cyan (#3FD4F5 up to #B8F4FF),
        // and an azure river sat close enough in hue that the Tons through
        // Nanda Ki Chowki read as just another road. Pushing the water toward
        // a saturated blue separates it by hue rather than by brightness,
        // which is the only axis neon leaves free -- everything there is
        // already bright. It still reads as water in dark and light, so this
        // stays one colour in all three themes rather than becoming a
        // per-theme special case.
        lineColor: '#1F86E8',
        lineWidth: _rankedWidth(2.0, 6.0, 13.0),
        lineOpacity: 0.95,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['!=', 'k', 'water'],
      enableInteraction: false,
    );

    // The name, repeated along the channel. This is the half that makes the
    // river "tell you where it is going" rather than just being a blue line:
    // symbolPlacement 'line' bends the glyphs to follow the water, and the
    // repeat means you pick up the name wherever you happen to be looking.
    await c.addSymbolLayer(
      waterSourceId,
      waterLabelLayerId,
      const SymbolLayerProperties(
        textField: ['get', 'name'],
        textSize: [
          'interpolate',
          ['linear'],
          ['zoom'],
          13, 10.0,
          16, 12.0,
          18, 13.5,
        ],
        textColor: '#BFE8FF',
        // Dark halo in both themes on purpose: the label sits ON the blue
        // ribbon, not on the basemap, so it needs to contrast with the water
        // rather than with the page behind it.
        textHaloColor: '#06243A',
        textHaloWidth: 1.6,
        textHaloBlur: 0.3,
        textLetterSpacing: 0.08,
        symbolPlacement: 'line',
        symbolSpacing: 260.0,
        // ONE font -- see the long note in addAreaLabels.
        textFont: ['Noto Sans Bold'],
      ),
      // Named watercourses only. An unnamed ditch labelled "" would just eat
      // collision budget.
      filter: const [
        'all',
        ['!=', 'k', 'water'],
        ['has', 'name'],
      ],
      minzoom: 12.5,
      enableInteraction: false,
    );
  }

  /// Draws the main corridor: Nanda Ki Chowki -> Pondha -> Kandholi -> UPES
  /// Bidholi, routed over the real road network by tool/fetch_overlays.py.
  ///
  /// This is not a road class you can select with a style filter -- the route
  /// is a dozen separate OSM ways with different names and classifications --
  /// which is why it ships as its own baked geometry.
  ///
  /// Amber, and drawn above the road contrast layer, so it reads as "the road
  /// that matters" against a network that is otherwise uniformly blue-grey.
  /// Three passes: halo, dark casing, bright core. The casing is what keeps it
  /// legible on the pale light basemap, where a bare amber line on near-white
  /// would wash out.
  static Future<void> addCorridor(MapLibreMapController c) async {
    final geo = await _corridorGeoJson();

    for (final id in const [
      corridorSpurLayerId,
      corridorSpurGlowLayerId,
      corridorCoreLayerId,
      corridorCaseLayerId,
      corridorGlowLayerId,
    ]) {
      await _dropLayer(c, id);
    }
    await _dropSource(c, corridorSourceId);
    await c.addGeoJsonSource(corridorSourceId, geo);

    // The spur first, so the main line draws over it at the junction.
    //
    // Soft halo plus a DASHED core, and no hard casing: a solid casing under a
    // dashed line shows through the gaps and reads as a broken outline. The
    // dash is what marks this as the optional branch -- same amber as the
    // corridor, because it is part of the same route system, but visibly not
    // the through road.
    await c.addLineLayer(
      corridorSourceId,
      corridorSpurGlowLayerId,
      const LineLayerProperties(
        lineColor: '#FFB020',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 5.0,
          16, 12.0,
          19, 22.0,
        ],
        lineOpacity: 0.24,
        lineBlur: 4.0,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['==', 'k', 'spur'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      corridorSourceId,
      corridorSpurLayerId,
      const LineLayerProperties(
        lineColor: '#FFB020',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 2.4,
          16, 5.6,
          19, 10.5,
        ],
        // Dash lengths are multiples of the line WIDTH, so this stays
        // proportional as the line thickens with zoom -- no need to ramp it.
        //
        // Short gaps on purpose. The dash READ as translucent at [2.2, 1.5]:
        // each gap exposed the dark basemap, and at a glance the eye averages
        // ink and gap together, so a fully opaque line looked like a faded
        // one. More ink per dash fixes it without losing the dashed meaning.
        lineDasharray: [2.6, 1.0],
        lineOpacity: 1.0,
        lineCap: 'butt',
        lineJoin: 'round',
      ),
      filter: const ['==', 'k', 'spur'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      corridorSourceId,
      corridorGlowLayerId,
      const LineLayerProperties(
        lineColor: '#FFB020',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 7.0,
          16, 17.0,
          19, 32.0,
        ],
        lineOpacity: 0.18,
        lineBlur: 4.0,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['==', 'k', 'main'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      corridorSourceId,
      corridorCaseLayerId,
      const LineLayerProperties(
        lineColor: '#5A3600',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 4.2,
          16, 9.5,
          19, 18.0,
        ],
        lineOpacity: 0.85,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['==', 'k', 'main'],
      enableInteraction: false,
    );

    await c.addLineLayer(
      corridorSourceId,
      corridorCoreLayerId,
      const LineLayerProperties(
        lineColor: '#FFB020',
        lineWidth: [
          'interpolate',
          ['exponential', 1.5],
          ['zoom'],
          12, 2.4,
          16, 6.0,
          19, 12.0,
        ],
        lineOpacity: 0.98,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: const ['==', 'k', 'main'],
      enableInteraction: false,
    );
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
    for (final id in [userPulseLayerId, userAccuracyLayerId, userDotLayerId]) {
      await _dropLayer(c, id);
    }
    await _dropSource(c, userSourceId);
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
    await _dropLayer(c, areaLabelLayerId);
    // Still dropped, though nothing adds it any more: a device that ran an
    // older build has the layer in its style, and a theme swap re-runs this
    // method against that same style object.
    await _dropLayer(c, areaLabelHaloLayerId);
    await _dropSource(c, areaLabelSourceId);
    await c.addGeoJsonSource(areaLabelSourceId, _areaLabelGeoJson());

    // No marker dot -- the name alone marks the place.
    //
    // The dot was a second symbol competing with the corridor and its spur for
    // the same few pixels, and at corridor zoom four of them read as hazard
    // pins, which is the one thing a blue dot on this map must not do.

    await c.addSymbolLayer(
      areaLabelSourceId,
      areaLabelLayerId,
      SymbolLayerProperties(
        textField: ['get', 'name'],
        // Big, and only gently smaller as you zoom in.
        //
        // These are the four places the whole app is scoped to, not incidental
        // map furniture, so they are meant to be the thing you read first.
        // They still taper with zoom because up close the surrounding detail
        // carries the context and a full-size name would just be in the way.
        textSize: [
          'interpolate',
          ['linear'],
          ['zoom'],
          12.5, 21.0,
          15, 18.0,
          18, 15.0,
        ],
        textColor: dark ? '#FFFFFF' : '#0E1A26',
        // A heavy halo in the background colour is what keeps these readable
        // over a busy road network without a filled plate behind them.
        textHaloColor: dark ? '#050D16' : '#FFFFFF',
        textHaloWidth: 2.0,
        textHaloBlur: 0.4,
        textLetterSpacing: 0.12,
        // Centred on the point now that there is no dot to sit above.
        textOffset: const [0, 0],
        textAnchor: 'center',
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
    for (final id in [maskFillLayerId, maskHatchLayerId, maskEdgeLayerId]) {
      await _dropLayer(c, id);
    }
    await _dropSource(c, maskSourceId);
    await _dropSource(c, '$maskSourceId-edge');

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

  /// Creates (or recreates) the empty pin source.
  ///
  /// Separate from [addPinLayers] because the source has to be dropped before
  /// the layers that reference it are rebuilt, and adding a source id that
  /// already exists throws.
  static Future<void> addPinSource(MapLibreMapController c) async {
    for (final id in [pinGlowLayerId, pinCoreLayerId, pinCountLayerId]) {
      await _dropLayer(c, id);
    }
    await _dropSource(c, pinSourceId);
    await c.addGeoJsonSource(pinSourceId, pinsGeoJson(const []));
  }

  static Future<void> addPinLayers(MapLibreMapController c) async {
    for (final id in [pinGlowLayerId, pinCoreLayerId, pinCountLayerId]) {
      await _dropLayer(c, id);
    }
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
