import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Fetches a basemap style and strips the layers RoadScan replaces, before
/// MapLibre ever sees it.
///
/// Why not just remove the layers after the style loads
/// ----------------------------------------------------
/// That is what this used to do, and it produced a visible flash: setStyle
/// applies the new style and starts rendering it immediately, so the
/// basemap's own building layers were drawn for a frame or two before the
/// removal call landed. Switching theme showed a blink of the old sparse OSM
/// wedges every time.
///
/// MapLibre accepts a style as raw JSON as well as a URL, so the layers can be
/// taken out before it is handed over. The style then never contains them and
/// there is nothing to flash.
///
/// The rewritten JSON is cached per URL for the life of the process, so the
/// cost is one fetch per style -- which MapLibre would have paid anyway.
class MapStyle {
  MapStyle._();

  static final Map<String, String> _cache = {};

  /// Layers dropped from every basemap.
  ///
  /// `building` / `building-3d` are the basemap's own footprints: 151 of them
  /// across the corridor, 8 literal triangles, none with a height. The
  /// bundled Microsoft dataset replaces them entirely.
  static const _dropLayerIds = {'building', 'building-3d'};

  /// Returns a style MapLibre can load: rewritten JSON when the fetch and
  /// parse succeed, otherwise the original URL.
  ///
  /// Falling back to the URL matters -- a network hiccup here should cost the
  /// flash fix, not the map.
  static Future<String> resolve(String url) async {
    final cached = _cache[url];
    if (cached != null) return cached;

    try {
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        debugPrint('RoadScan: style fetch ${res.statusCode} for $url; '
            'using the URL directly');
        return url;
      }

      final style = json.decode(utf8.decode(res.bodyBytes))
          as Map<String, dynamic>;
      final layers = style['layers'];
      if (layers is! List) return url;

      final before = layers.length;
      layers.removeWhere((l) =>
          l is Map &&
          (_dropLayerIds.contains(l['id']) ||
              // Belt and braces: catch any other layer drawing from the
              // building source-layer, whatever it happens to be called in a
              // style we have not inspected.
              l['source-layer'] == 'building'));

      debugPrint('RoadScan: style $url -- dropped '
          '${before - layers.length} building layer(s)');

      return _cache[url] = json.encode(style);
    } catch (e) {
      debugPrint('RoadScan: could not rewrite style $url ($e); '
          'using the URL directly');
      return url;
    }
  }

  /// Pre-fetches a style so a later switch to it is instant.
  static Future<void> warm(String url) => resolve(url).then((_) {});
}
