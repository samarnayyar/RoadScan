import 'dart:math' as math;

import '../models/detection.dart';

/// How big the damage is on the ground, in metres, estimated from one photo.
///
/// The honest framing first: this is an ESTIMATE under assumptions, not a
/// measurement. Recovering true metric scale from a single image is
/// impossible without one of a known camera height and tilt, a reference
/// object of known size in frame, stereo or multi-view capture, a monocular
/// depth model, or a depth sensor. The app has none of those. EXIF sometimes
/// carries focal length; it never carries how high above the road the phone
/// was held.
///
/// So the camera pose is assumed, and the arithmetic from there is exact.
/// That is a defensible position -- the assumption is stated, its failure
/// mode is understood, and the result degrades gracefully -- but it must be
/// described as an estimate wherever it is shown to a user or a marker.
///
/// The model
/// ---------
/// A pinhole camera at [cameraHeightM] above a flat road, tilted
/// [cameraPitchDeg] below horizontal, looking along the direction the phone
/// is pointing. Each corner of the detection box is a ray; where that ray
/// meets the road plane is that corner's ground position. The footprint is
/// the extent of those four points.
///
/// Flat-road assumption included: on a cambered or sloping surface the plane
/// is wrong and the estimate stretches or compresses along the slope. On the
/// Bidholi hill roads that is a real error source, and it grows with
/// distance, which is why [estimate] refuses far-field boxes rather than
/// returning a confident-looking number for them.
class GroundFootprint {
  const GroundFootprint({
    required this.widthM,
    required this.lengthM,
    required this.distanceM,
  });

  /// Across the direction of view -- the road's width direction, roughly.
  final double widthM;

  /// Along the direction of view. Larger than [widthM] for the same defect
  /// because the ground plane is foreshortened away from the camera.
  final double lengthM;

  /// Ground distance from the photographer to the centre of the damage.
  /// Reported because the estimate's error grows with it.
  final double distanceM;

  /// Typical height a phone is held at when someone photographs a road.
  ///
  /// Chest height for an adult standing and angling the phone down, which is
  /// what the capture flow asks for. A photo taken from a motorbike or a car
  /// window sits higher and the footprint comes out too large; one taken
  /// crouching comes out too small. Error scales linearly with this, so a
  /// 30% wrong height gives a 30% wrong size -- large, but not catastrophic
  /// for a marker whose job is "roughly this big".
  static const double cameraHeightM = 1.35;

  /// Downward tilt from horizontal.
  ///
  /// 50 rather than 45: a person photographing damage at their feet tilts
  /// further down than halfway. This matters more than the height does,
  /// because distance goes as 1/tan(angle) and so blows up as the angle
  /// approaches horizontal -- which is exactly the far-field case [estimate]
  /// rejects.
  static const double cameraPitchDeg = 50.0;

  /// Horizontal field of view for a typical phone main camera (~26 mm
  /// equivalent). Used with the image aspect ratio to derive the vertical
  /// FOV, rather than assuming both.
  static const double horizontalFovDeg = 67.0;

  /// Beyond this the estimate is not worth reporting.
  ///
  /// Ground distance is h / tan(angle below horizontal), so error grows
  /// without bound as a box approaches the horizon: a few pixels of box
  /// position become tens of metres of distance. Returning null is more
  /// useful than returning a number nobody should trust.
  static const double maxTrustedDistanceM = 12.0;

  /// Estimates the ground footprint of [d] in a photo of aspect [aspectRatio]
  /// (width / height). Returns null when the geometry is untrustworthy.
  static GroundFootprint? estimate(Detection d, double aspectRatio) {
    if (aspectRatio <= 0) return null;

    final pitch = _rad(cameraPitchDeg);
    final tanH = math.tan(_rad(horizontalFovDeg) / 2);
    // Vertical FOV follows from the horizontal one and the frame shape.
    final tanV = tanH / aspectRatio;

    // The four box corners, as normalised offsets from frame centre in
    // [-1, 1], with y positive downward.
    final corners = <List<double>>[
      [d.left * 2 - 1, d.top * 2 - 1],
      [d.right * 2 - 1, d.top * 2 - 1],
      [d.right * 2 - 1, d.bottom * 2 - 1],
      [d.left * 2 - 1, d.bottom * 2 - 1],
    ];

    final xs = <double>[];
    final ys = <double>[];

    for (final c in corners) {
      final nx = c[0], ny = c[1];

      // Camera basis in world axes (x right, y forward-horizontal, z up),
      // pitched down by `pitch`.
      //   forward = (0, cos p, -sin p)
      //   up      = (0, sin p,  cos p)
      //   right   = (1, 0, 0)
      // A pixel below frame centre (ny > 0) points further down, hence the
      // minus on the up term.
      final dirX = nx * tanH;
      final dirY = math.cos(pitch) - ny * tanV * math.sin(pitch);
      final dirZ = -math.sin(pitch) - ny * tanV * math.cos(pitch);

      // Ray from (0, 0, h) meets the road plane z = 0 only if it descends.
      // A corner above the horizon has no ground intersection at all -- the
      // box includes sky or a distant hillside, which means this is not a
      // photo of road at the photographer's feet.
      if (dirZ >= -1e-6) return null;

      final t = cameraHeightM / -dirZ;
      xs.add(t * dirX);
      ys.add(t * dirY);
    }

    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);

    final width = maxX - minX;
    final length = maxY - minY;
    final distance = (minY + maxY) / 2;

    if (!width.isFinite || !length.isFinite || !distance.isFinite) return null;
    if (distance <= 0 || distance > maxTrustedDistanceM) return null;
    // A defect narrower than a few centimetres is below what this method can
    // resolve; one wider than a carriageway means the geometry has failed.
    if (width < 0.05 || width > 12.0) return null;
    if (length < 0.05 || length > 20.0) return null;

    return GroundFootprint(
      widthM: width,
      lengthM: length,
      distanceM: distance,
    );
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  @override
  String toString() => 'GroundFootprint(${widthM.toStringAsFixed(2)} x '
      '${lengthM.toStringAsFixed(2)} m at ${distanceM.toStringAsFixed(1)} m)';
}
