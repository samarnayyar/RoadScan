import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
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
    setState(() {
      _current = target;
      _moving = false;
      // Track whether the user actually changed anything, so we can report the
      // final position's provenance honestly.
      if (_distanceFromInitial(target) > 2) _moved = true;
    });
  }

  double _distanceFromInitial(LatLng p) {
    // Rough metres; only used to decide "did this move at all".
    const mPerDegLat = 111320.0;
    final dLat = (p.latitude - widget.initial.latitude) * mPerDegLat;
    final dLon = (p.longitude - widget.initial.longitude) * mPerDegLat * 0.86;
    return (dLat * dLat + dLon * dLon) > 0
        ? (dLat.abs() + dLon.abs())
        : 0;
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
              // Close in hard: at z18 a screen pixel is ~0.3 m, so the user can
              // actually place the pin on a specific pothole rather than a
              // general stretch of road.
              zoom: 18.5,
              tilt: 0,
            ),
            onMapCreated: (c) => _controller = c,
            onStyleLoadedCallback: () async {
              try {
                await MapLayers.addBuildings(_controller!);
              } catch (_) {
                /* buildings are cosmetic here */
              }
            },
            onCameraIdle: _onCameraIdle,
            onCameraTrackingDismissed: () => setState(() => _moving = true),
            myLocationEnabled: true,
            trackCameraPosition: true,
            // Flat and north-up: tilt would make it much harder to judge
            // exactly which bit of road the pin is over.
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
