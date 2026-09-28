import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/detection.dart' show SeverityClass;

/// The hazard marker, drawn at runtime rather than shipped as an asset.
///
/// Why not a circle
/// ----------------
/// A coloured disc on a map is ambiguous: it reads as an area, a radius, a
/// heat spot -- anything but "a thing is here". It also stacks badly. Once the
/// corridor carries dozens of hazards, discs merge into a rash of blobs with
/// no clear centres, and the map stops being scannable exactly when there is
/// most to scan.
///
/// A teardrop fixes both. Its tip says precisely where, its head carries a
/// glyph that says what, and because the head sits ABOVE the point, two
/// markers close together overlap at the head while their tips stay distinct.
///
/// Why generated
/// -------------
/// Four severities at whatever size and colour the theme wants, from about
/// forty lines of canvas, with no PNGs to keep in sync with the palette and
/// no asset bundle to grow. The bitmaps are made once per style load and
/// handed to MapLibre's own image atlas, so drawing them costs nothing per
/// frame.
class PinIcons {
  PinIcons._();

  /// Rendered large and drawn down at [iconScale], so the marker stays crisp
  /// on a high-density screen without shipping three sizes.
  static const double _w = 120.0;
  static const double _h = 156.0;

  /// Measured on the device, not guessed.
  ///
  /// The 156px-tall bitmap renders at 156 / devicePixelRatio logical pixels
  /// per unit of total icon scale. On the 640dpi test phone that ratio is 4,
  /// so a critical marker (severity factor 1.3) comes out 39 * 1.3 *
  /// iconScale tall:
  ///
  ///   0.33  ->  11 x 17   too small to hit, smaller than the place labels
  ///   0.65  ->  25 x 33   about a fingertip, reads as a marker
  ///   1.10  ->  43 x 56   Google-Maps sized, too heavy on a dense map
  ///
  /// 0.65 is the middle, and the size settled on against the real screen.
  static const double iconScale = 0.65;

  /// How tall the LARGEST marker draws, in logical pixels, on a screen of
  /// [devicePixelRatio].
  ///
  /// A function, not a constant, because the bitmap is a fixed number of
  /// DEVICE pixels and the logical size therefore depends on the screen. This
  /// phone reports 640dpi, so a ratio of 4 -- assuming the usual 3 made every
  /// layout figure derived from it a third too large.
  ///
  /// The icon is anchored at its tip, so it occupies this much screen ABOVE
  /// the hazard's position, and anything placed over a marker has to clear
  /// that or it covers the pin it belongs to. 1.3 is the critical severity's
  /// size factor; see _iconSizeFor.
  static double maxLogicalHeight(double devicePixelRatio) =>
      (_h / devicePixelRatio) * 1.3 * iconScale;

  static String nameFor(SeverityClass s) => 'roadscan-pin-${s.name}';

  /// Adds one image per severity to the style's atlas.
  ///
  /// Must run after every style change: setStyle throws the atlas away along
  /// with the layers, and a symbol layer whose icon is missing renders
  /// nothing at all -- silently, which is the worst way for this to fail.
  static Future<void> register(
    MapLibreMapController c,
    Color Function(SeverityClass) colorFor,
  ) async {
    for (final s in SeverityClass.values) {
      final bytes = await _draw(colorFor(s));
      await c.addImage(nameFor(s), bytes);
    }
  }

  static Future<Uint8List> _draw(Color fill) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    const stroke = 9.0;
    final r = (_w - stroke) / 2;
    const cx = _w / 2;
    final cy = stroke / 2 + r;
    const tipY = _h - stroke / 2;

    // Where the sides of the drop meet the head: the tangent points from the
    // tip to the circle. Computing them rather than eyeballing a curve is
    // what keeps the join seamless at any head size.
    final d = tipY - cy;
    final alpha = math.acos((r / d).clamp(-1.0, 1.0));
    final start = math.pi / 2 - alpha;

    final rect = Rect.fromCircle(center: const Offset(cx, 0) + Offset(0, cy), radius: r);
    final path = Path()
      ..moveTo(cx, tipY)
      // Straight up the right flank to the tangent point, round the head the
      // long way over the top, and close() returns down the left flank.
      ..arcTo(rect, start, -(2 * math.pi - 2 * alpha), false)
      ..close();

    // Shadow first, so the marker sits on the map rather than floating over
    // it. Offset down, which is where the map's light comes from.
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );

    // An exclamation mark, not a dot. The colour says how bad; the glyph has
    // to say "hazard" on a map already full of cafe and fuel pins.
    final glyph = Paint()..color = Colors.white;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - 9), width: 13, height: 40),
        const Radius.circular(6.5),
      ),
      glyph,
    );
    canvas.drawCircle(Offset(cx, cy + 22), 7.5, glyph);

    final image = await recorder.endRecording().toImage(_w.toInt(), _h.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}
