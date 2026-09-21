import 'package:flutter/material.dart';

import '../models/detection.dart';
import '../services/severity.dart';

/// Draws detection boxes over the captured photo.
///
/// Detections carry normalised (0..1) coordinates, so this maps them onto
/// whatever rect the image actually occupies after BoxFit.contain letterboxing.
/// Painting against the widget's full size instead would put every box off by
/// the letterbox margin -- subtly wrong in a way that's easy to miss on one
/// device and glaring on another with a different aspect ratio.
class DetectionOverlay extends StatelessWidget {
  const DetectionOverlay({
    super.key,
    required this.detections,
    required this.imageAspectRatio,
    this.driver,
  });

  final List<Detection> detections;

  /// width / height of the source image.
  final double imageAspectRatio;

  /// The detection that set the severity score, drawn emphasised.
  final Detection? driver;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rect = _containedRect(
          constraints.biggest,
          imageAspectRatio,
        );
        return CustomPaint(
          size: constraints.biggest,
          painter: _BoxPainter(
            detections: detections,
            driver: driver,
            imageRect: rect,
          ),
        );
      },
    );
  }

  /// Where a BoxFit.contain image of [aspect] lands inside [box].
  static Rect _containedRect(Size box, double aspect) {
    if (aspect <= 0 || box.width <= 0 || box.height <= 0) {
      return Offset.zero & box;
    }
    final boxAspect = box.width / box.height;
    if (boxAspect > aspect) {
      // Box is wider than the image: pillarboxed, full height.
      final w = box.height * aspect;
      return Rect.fromLTWH((box.width - w) / 2, 0, w, box.height);
    }
    final h = box.width / aspect;
    return Rect.fromLTWH(0, (box.height - h) / 2, box.width, h);
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.detections,
    required this.driver,
    required this.imageRect,
  });

  final List<Detection> detections;
  final Detection? driver;
  final Rect imageRect;

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in detections) {
      final isDriver = identical(d, driver);
      final score = Severity.scoreForDetection(d);
      final color = _colorFor(score);

      final r = Rect.fromLTRB(
        imageRect.left + d.left * imageRect.width,
        imageRect.top + d.top * imageRect.height,
        imageRect.left + d.right * imageRect.width,
        imageRect.top + d.bottom * imageRect.height,
      );

      final rrect = RRect.fromRectAndRadius(r, const Radius.circular(6));

      // A dark outer stroke under the coloured one keeps boxes legible over
      // pale tarmac, where a thin bright line disappears.
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDriver ? 5.0 : 3.5
          ..color = Colors.black.withValues(alpha: 0.35),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDriver ? 3.0 : 2.0
          ..color = color,
      );

      if (isDriver) {
        canvas.drawRRect(
          rrect,
          Paint()..color = color.withValues(alpha: 0.14),
        );
      }

      _paintLabel(
        canvas,
        '${d.hazard.label}  ${(d.confidence * 100).round()}%',
        r,
        color,
        size,
      );
    }
  }

  void _paintLabel(
    Canvas canvas,
    String text,
    Rect box,
    Color color,
    Size size,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padH = 6.0, padV = 3.0;
    final w = tp.width + padH * 2;
    final h = tp.height + padV * 2;

    // Flip the label below the box when there's no room above it, so boxes
    // near the top edge don't get their labels clipped off-screen.
    final above = box.top - h >= 0;
    final left = box.left.clamp(0.0, (size.width - w).clamp(0.0, size.width));
    final top = above ? box.top - h : box.top;

    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(4),
    );
    canvas.drawRRect(bg, Paint()..color = color);
    tp.paint(canvas, Offset(left + padH, top + padV));
  }

  Color _colorFor(double score) {
    final cls = Severity.classify(score);
    return switch (cls) {
      SeverityClass.low => const Color(0xFF3FA34D),
      SeverityClass.medium => const Color(0xFFE8B21A),
      SeverityClass.high => const Color(0xFFE2661C),
      SeverityClass.critical => const Color(0xFFD32F2F),
    };
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.detections != detections ||
      old.driver != driver ||
      old.imageRect != imageRect;
}
