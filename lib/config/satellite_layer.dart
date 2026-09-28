import 'package:maplibre_gl/maplibre_gl.dart';

/// Aerial imagery, drawn over the vector basemap inside the SAME map.
///
/// Why this and not Google's map
/// -----------------------------
/// The question a second view answers is "what does this stretch of road
/// actually look like", and imagery answers it. Google's SDK answers it too,
/// but at the cost of a second renderer in the app, a billing account on the
/// project, and a key that has to be restricted and rotated. More to the
/// point, a Google map is a separate surface: the hazard bands and the
/// markers cannot be drawn on it, so switching to it threw away everything
/// RoadScan knows and showed a bare map instead.
///
/// A raster layer keeps all of that. The imagery slides in UNDER the app's own
/// layers and over the basemap, so the same hazards and the same alert bands
/// sit on top of real photography. That is strictly more useful than either
/// view was alone, and it costs nothing.
///
/// About the source
/// ----------------
/// Esri's World Imagery tile service, which serves without a key. It is a
/// long-standing public endpoint rather than a contractual free tier, so it
/// carries the attribution Esri asks for and the app degrades to the vector
/// basemap if it ever stops answering -- the toggle would simply show nothing
/// new rather than breaking the map. For a corridor this size the imagery is
/// sub-metre and resolves individual vehicles.
class SatelliteLayer {
  SatelliteLayer._();

  static const String sourceId = 'roadscan-satellite';
  static const String layerId = 'roadscan-satellite-raster';

  static const String _tileUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/'
      'MapServer/tile/{z}/{y}/{x}';

  /// Esri asks for this wherever the imagery is shown.
  static const String attribution =
      'Imagery © Esri, Maxar, Earthstar Geographics';

  /// Beyond this the service starts returning thin or empty tiles over this
  /// corridor, so MapLibre is told to upsample z18 rather than request z19+
  /// and paint the gaps grey. The map zooms in well past this, and a
  /// softened photo there is better than a hole.
  static const double maxZoom = 18;

  /// Adds the source and layer, hidden.
  ///
  /// [belowLayerId] must be the app's own lowest layer, so the imagery covers
  /// the basemap's roads and labels but never the hazards drawn above it.
  static Future<void> addLayer(
    MapLibreMapController c, {
    String? belowLayerId,
  }) async {
    try {
      await c.removeLayer(layerId);
    } catch (_) {/* not present */}
    try {
      await c.removeSource(sourceId);
    } catch (_) {/* not present */}

    await c.addSource(
      sourceId,
      RasterSourceProperties(
        tiles: [_tileUrl],
        tileSize: 256,
        maxzoom: maxZoom,
        attribution: attribution,
      ),
    );

    await c.addRasterLayer(
      sourceId,
      layerId,
      const RasterLayerProperties(rasterOpacity: 1.0),
      belowLayerId: belowLayerId,
    );

    // Added hidden: the app opens on its own styled map, and a flash of
    // satellite on every style load would be a lie about which view is on.
    await c.setLayerVisibility(layerId, false);
  }

  static Future<void> setVisible(
    MapLibreMapController c,
    bool visible,
  ) =>
      c.setLayerVisibility(layerId, visible);
}
