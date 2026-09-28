import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
import '../services/admin_mode.dart';
import '../config/map_layers.dart';
import '../services/photo_metadata.dart';

/// Lets the user place the hazard precisely on the map.
///
/// Why this screen exists: a raw GPS fix is 5-10 m out at best, worse under
/// tree cover, and a gallery photo's EXIF position is wherever the phone
/// *thought* it was when the shutter fired. The dedup radius is 20 m, so a
/// 15 m error is the difference between confirming an existing pothole and
/// inventing a second one beside it. The person who took the photo knows where
/// the hole actually is; this lets them say so.
///
/// The pin stays pinned to the centre of the screen and the MAP moves under it,
/// rather than dragging a marker around. Dragging a marker means your thumb
/// covers the exact spot you are aiming at.
class AdjustLocationScreen extends StatefulWidget {
  const AdjustLocationScreen({
    super.key,
    required this.initial,
    required this.source,
    this.accuracyMeters,
  });

  final LatLng initial;
  final MetadataSource source;
  final double? accuracyMeters;

  @override
  State<AdjustLocationScreen> createState() => _AdjustLocationScreenState();
}

class _AdjustLocationScreenState extends State<AdjustLocationScreen> {
  MapLibreMapController? _controller;
  late LatLng _current = widget.initial;
  bool _moving = false;
  bool _moved = false;

  void _onCameraIdle() {
    final target = _controller?.cameraPosition?.target;
    if (target == null) return;

    // Pull the pin back onto the circle if it escaped.
    //
    // cameraTargetBounds takes a SQUARE, so on its own it permits the corners
    // -- 100 m x sqrt(2), about 141 m diagonally -- which sit outside the
    // circle drawn on screen. The clamp and the picture disagreed, and the
    // picture is the promise. This enforces the circle the user can actually
    // see. The square bounds stay as the cheap first line of defence: they
    // stop the fling during the gesture, and this only has to tidy up the
    // corners afterwards.
    final radius = _radius;
    if (_metresFromInitial(target) > radius) {
      final clamped = _clampToRadius(target, radius);
      setState(() {
        _current = clamped;
        _moving = false;
        _moved = true;
      });
      _controller?.animateCamera(
        CameraUpdate.newLatLng(clamped),
        duration: const Duration(milliseconds: 220),
      );
      return;
    }

    setState(() {
      _current = target;
      _moving = false;
      // Track whether the user actually changed anything, so we can report the
      // final position's provenance honestly.
      if (_metresFromInitial(target) > 2) _moved = true;
    });
  }

  /// The nearest point on the allowed circle to [p].
  ///
  /// Scaling happens in METRES, then converts back to degrees, because a
  /// degree of longitude is shorter than a degree of latitude everywhere but
  /// the equator. Normalising the raw degree offsets would put the clamped
  /// point off the circle it is supposed to land on, worst at the diagonals.
  /// How far the pin may be dragged from where the photo was taken.
  ///
  /// Normally 100m -- wide enough for a genuine GPS correction, tight enough
  /// that a photo cannot be relocated across town. In admin mode the limit is
  /// effectively lifted to the operating square, which is the whole point of
  /// that mode: testing the corridor without standing on it.
  double get _radius => AdminMode.instance.isOn
      ? 50000.0
      : AppConfig.locationAdjustRadiusMeters;

  LatLng _clampToRadius(LatLng p, double radius) {
    const mPerDegLat = 111320.0;
    final cosLat = math.cos(widget.initial.latitude * math.pi / 180.0);
    final safeCos = cosLat.abs() < 0.01 ? 0.01 : cosLat;

    final dLatM = (p.latitude - widget.initial.latitude) * mPerDegLat;
    final dLonM =
        (p.longitude - widget.initial.longitude) * mPerDegLat * safeCos;
    final dist = math.sqrt(dLatM * dLatM + dLonM * dLonM);
    if (dist <= radius || dist == 0) return p;

    final k = radius / dist;
    return LatLng(
      widget.initial.latitude + (dLatM * k) / mPerDegLat,
      widget.initial.longitude + (dLonM * k) / (mPerDegLat * safeCos),
    );
  }

  /// A square of +/- [metres] around [centre], for the camera clamp.
  ///
  /// Longitude degrees shrink with latitude, so the longitude span is widened
  /// by 1/cos(lat). Using the same delta for both axes would give a box that
  /// is 50 m tall but only ~43 m wide at Dehradun's latitude -- a clamp that
  /// is tighter east-west than north-south for no reason anyone could guess.
  static LatLngBounds _boundsAround(LatLng centre, double metres) {
    const mPerDegLat = 111320.0;
    final dLat = metres / mPerDegLat;
    final cosLat = math.cos(centre.latitude * math.pi / 180.0);
    final dLon = metres / (mPerDegLat * (cosLat.abs() < 0.01 ? 0.01 : cosLat));
    return LatLngBounds(
      southwest: LatLng(centre.latitude - dLat, centre.longitude - dLon),
      northeast: LatLng(centre.latitude + dLat, centre.longitude + dLon),
    );
  }

  /// Metres between [p] and where the photo said it was taken.
  ///
  /// Proper Euclidean distance. The previous version computed the squared sum
  /// only to test it against zero and then returned |dLat| + |dLon| -- a
  /// Manhattan distance, which overstates by up to sqrt(2) on the diagonals.
  /// Harmless while it only answered "did this move at all"; not harmless now
  /// that it decides whether a pin is inside the allowed circle.
  ///
  /// cos(latitude) is computed rather than the hardcoded 0.86 it used before.
  /// That constant is right for about 30.5 degrees and wrong everywhere else,
  /// which is a trap for anyone who reuses this screen outside Dehradun.
  double _metresFromInitial(LatLng p) {
    const mPerDegLat = 111320.0;
    final cosLat = math.cos(widget.initial.latitude * math.pi / 180.0);
    final dLat = (p.latitude - widget.initial.latitude) * mPerDegLat;
    final dLon =
        (p.longitude - widget.initial.longitude) * mPerDegLat * cosLat;
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Place the hazard'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              AdjustedLocation(
                position: _current,
                source: _moved ? MetadataSource.manual : widget.source,
              ),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: AppConfig.mapStyleUrl,
            initialCameraPosition: CameraPosition(
              target: widget.initial,
              // Opens showing the WHOLE allowed circle, then the user zooms
              // in to place precisely.
              //
              // Measured at this latitude: 18.5 was ~0.36 m per logical
              // pixel, about 175 m across the screen -- narrower than the
              // 200 m circle, so the boundary sat off-screen at the exact
              // moment the user needed to understand it. Being stopped by a
              // limit you cannot see reads as the app being broken. 17.5 is
              // ~0.73 m/px, about 350 m across, so the whole circle fits with
              // room to spare and the rule explains itself on arrival.
              //
              // Zooming in is still available up to z20 (minMaxZoomPreference
              // below), which is where the fine placement actually happens.
              zoom: 17.5,
              // Pitched, matching the main map so the two read as the same
              // place rather than two different products.
              //
              // The trade-off is real and worth stating: a pitched view makes
              // it harder to judge exactly which bit of road the centre pin
              // sits over, because the ground plane is foreshortened toward
              // the top of the screen. The pin still resolves to a genuine
              // ground point -- cameraPosition.target is where screen centre
              // meets the ground -- so placement stays correct; it is only
              // eyeballing it that gets harder -- which is why this is 30
              // and not the main map's 45: enough tilt to read as the same
              // place, little enough that the ground stays judgeable.
              tilt: 30,
            ),
            // Confined to a square around where the photo says it was taken.
            //
            // MapLibre's camera clamp is RECTANGULAR -- there is no circular
            // equivalent -- so this square is the coarse limit and the circle
            // is enforced by _onCameraIdle pulling the pin back onto it. The
            // consequence is honest and visible: near the diagonals you can
            // drag slightly past the drawn edge and it springs back when you
            // let go, rather than being blocked mid-gesture. Shrinking the
            // square to fit inside the circle would prevent that, but would
            // also make the circle a lie in the other direction -- its north,
            // south, east and west edges would become unreachable at ~71 m
            // instead of the stated 100 m.
            //
            // Without a clamp this is a whole-world map: one careless fling
            // and the pin is in another district, which the app would then
            // file as a real hazard because nothing downstream re-checks it.
            // 50 m is wider than consumer GPS error (typically 5-10 m) so a
            // genuine correction always fits, while a gross relocation cannot
            // happen by accident. Someone whose photo is truly further out
            // than this should retake it rather than drag it across town.
            cameraTargetBounds: CameraTargetBounds(
              AdminMode.instance.isOn
                  // Admin: the whole operating square, so a report can be
                  // placed on any road without standing on it.
                  ? AppConfig.campusBounds
                  : _boundsAround(widget.initial, _radius),
            ),
            onMapCreated: (c) => _controller = c,
            onStyleLoadedCallback: () async {
              // Same bundled footprints as the main map, not the basemap's
              // own extrusion. This screen is flat and zoomed to ~0.3 m per
              // pixel, so buildings are the main thing telling the user which
              // plot they are aiming at -- and the OSM layer here showed the
              // same handful of stray wedges rather than the real ones.
              try {
                await MapLayers.addMlBuildings(_controller!, dark: false);
              } catch (_) {
                /* buildings are an orientation aid here, not essential */
              }

              // The drag limit, drawn. Same hatch-and-dim language as the
              // corridor square on the main map, so it reads as "not here"
              // without needing a caption. Without it the clamp is invisible
              // until the map stops responding, which feels like a bug.
              try {
                String? hatchId;
                final hatch = await MapLayers.makeHatchImage();
                if (hatch != null) {
                  hatchId = 'roadscan-hatch';
                  await _controller!.addImage(hatchId, hatch);
                }
                // No mask in admin mode: there is no circle to show when
                // the whole square is in range.
                if (!AdminMode.instance.isOn) {
                  await MapLayers.addRadiusMask(
                    _controller!,
                    centre: widget.initial,
                    radiusMeters: _radius,
                    hatchImageId: hatchId,
                  );
                }
              } catch (e) {
                // The camera clamp is the real restriction; this only shows
                // where it is. Losing it must not lose the screen.
                debugPrint('RoadScan: radius mask unavailable: $e');
              }
            },
            onCameraIdle: _onCameraIdle,
            onCameraTrackingDismissed: () => setState(() => _moving = true),
            myLocationEnabled: true,
            trackCameraPosition: true,
            // Pitch is fixed at 30: the user cannot flatten it or tip it
            // further, so every placement is judged from the same viewpoint
            // and two reports of the same pothole are comparable.
            tiltGesturesEnabled: false,
            rotateGesturesEnabled: false,
            minMaxZoomPreference: const MinMaxZoomPreference(15, 20),
          ),

          // Fixed centre pin. Lifts slightly while the map is moving.
          IgnorePointer(
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                transform: Matrix4.translationValues(0, _moving ? -12 : -4, 0),
                child: const _CentrePin(),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _InfoPanel(
              position: _current,
              source: _moved ? MetadataSource.manual : widget.source,
              accuracyMeters: widget.accuracyMeters,
              moved: _moved,
            ),
          ),
        ],
      ),
    );
  }
}

class AdjustedLocation {
  const AdjustedLocation({required this.position, required this.source});
  final LatLng position;
  final MetadataSource source;
}

class _CentrePin extends StatelessWidget {
  const _CentrePin();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.location_on, size: 46, color: Color(0xFFD32F2F)),
        // Small ground dot: the icon's tip is ambiguous, this marks the exact
        // point the coordinate refers to.
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
        ),
      ],
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.position,
    required this.source,
    required this.accuracyMeters,
    required this.moved,
  });

  final LatLng position;
  final MetadataSource source;
  final double? accuracyMeters;
  final bool moved;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 14),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              moved
                  ? 'Position set by you'
                  : 'Position ${source.label}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              '${position.latitude.toStringAsFixed(6)}, '
              '${position.longitude.toStringAsFixed(6)}'
              '${accuracyMeters != null && !moved ? '  (+/-${accuracyMeters!.round()} m)' : ''}',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 10),
            Text(
              'Drag the map so the pin sits exactly on the damage. Reports '
              'within ${AppConfig.dedupRadiusMeters.round()} m of each other '
              'are treated as the same hazard.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
