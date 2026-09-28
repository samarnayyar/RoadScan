import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_theme.dart';
import '../models/hazard_report.dart';
import '../services/supabase_service.dart';

/// The callout shown when a hazard pin is tapped.
///
/// Anchored to the pin with a pointer tail, not parked at the bottom of the
/// screen. On a map with several hazards in view, a card at the bottom leaves
/// the user to work out WHICH pin it is describing; a tail answers that
/// without a word. It also keeps the road either side of the hazard visible,
/// which a modal sheet does not -- and that road is what the rider is
/// deciding about.
///
/// Layout is facts and severity on the LEFT, photo on the RIGHT, with the
/// actions in a tinted strip along the bottom. The text is the answer, so it
/// gets the reading position; the photo corroborates it.
class PinPopup extends StatelessWidget {
  const PinPopup({
    super.key,
    required this.report,
    required this.onDismiss,
    required this.onOpenDetail,
    this.tailFraction = 0.5,
    this.tailBelow = true,
  });

  final HazardReport report;
  final VoidCallback onDismiss;
  final VoidCallback onOpenDetail;

  /// Where along the card's width the tail sits, 0 (left edge) to 1 (right).
  ///
  /// The card is clamped to stay on screen, so it is often NOT centred over
  /// its pin; the tail slides instead, and keeps pointing at the right one.
  final double tailFraction;

  /// True when the card sits above its pin and the tail points down.
  final bool tailBelow;

  /// Width the map screen lays this out at, in logical pixels.
  ///
  /// Sized to fit the channel BETWEEN the tilt slider and the button rail.
  /// At 330 on this 360-wide screen the card was 92% of the width and sat on
  /// both of them; the controls are how the user gets out of whatever the
  /// card is describing, so they win. 232 leaves a clear margin either side.
  static const double cardWidth = 232.0;

  /// Height of the pointer triangle, which the anchor maths has to leave room
  /// for so the tip lands on the pin rather than beside it.
  static const double tailHeight = 11.0;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;

    final tail = _Tail(
      color: c.surface,
      border: c.border,
      pointsDown: tailBelow,
      fraction: tailFraction,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!tailBelow) tail,
        _card(context, c),
        if (tailBelow) tail,
      ],
    );
  }

  Widget _card(BuildContext context, RoadScanColors c) {
    final thumb = report.latestPhotoPath == null
        ? null
        : SupabaseService.instance.publicUrl(report.latestPhotoPath!);

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.border),
          boxShadow: const [
            BoxShadow(
                color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8)),
          ],
        ),
        // Clip so the action strip's fill follows the rounded corners.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(c),
                    const SizedBox(height: 9),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _facts(c)),
                        const SizedBox(width: 10),
                        _photo(c, thumb),
                      ],
                    ),
                  ],
                ),
              ),
              _actions(context, c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(RoadScanColors c) {
    // No hazard name. It read "Pothole" on every card, which is a word that
    // costs a line of the card's width and tells the user nothing they did
    // not know from tapping a hazard pin. The severity is the part that
    // differs, so it gets the space -- and the photo below gets the rest.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: report.color,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${report.severity.name.toUpperCase()} SEVERITY',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 28,
          height: 24,
          child: IconButton(
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            splashRadius: 18,
            icon: Icon(Icons.close, size: 18, color: c.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _facts(RoadScanColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Trust first. A pothole confirmed by four riders an hour ago is a
        // different proposition from one reported once last month, and that
        // distinction is what decides whether to act on it.
        _row(c, Icons.verified_outlined, _confirmText(report)),
        const SizedBox(height: 5),
        _row(c, Icons.schedule, _ago(report.lastConfirmedAt)),
        if (report.hasFootprint) ...[
          const SizedBox(height: 5),
          _row(
            c,
            Icons.straighten,
            '~${report.widthM!.toStringAsFixed(1)} x '
            '${report.lengthM!.toStringAsFixed(1)} m',
          ),
        ],
        if (report.distanceMeters != null) ...[
          const SizedBox(height: 5),
          _row(c, Icons.near_me_outlined, _distance(report.distanceMeters!)),
        ],
      ],
    );
  }

  Widget _photo(RoadScanColors c, String? thumb) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: 96,
        height: 82,
        child: thumb == null
            ? Container(
                color: c.surfaceAlt,
                child: Icon(Icons.no_photography_outlined,
                    size: 22, color: c.textMuted),
              )
            : Image.network(
                thumb,
                fit: BoxFit.cover,
                // A pin whose photo will not load must still render as a
                // usable card: the text on the left is the answer.
                errorBuilder: (_, __, ___) => Container(
                  color: c.surfaceAlt,
                  child: Icon(Icons.broken_image_outlined,
                      size: 22, color: c.textMuted),
                ),
                loadingBuilder: (ctx, child, progress) => progress == null
                    ? child
                    : Container(
                        color: c.surfaceAlt,
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: c.textMuted),
                          ),
                        ),
                      ),
              ),
      ),
    );
  }

  Widget _actions(BuildContext context, RoadScanColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: _action(c, Icons.article_outlined, 'Full report', onOpenDetail),
    );
  }

  Widget _action(
    RoadScanColors c,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: c.accent),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: c.accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _row(RoadScanColors c, IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 13, color: c.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: c.textSecondary, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  /// Kept short: the card is now narrow enough that "Confirmed by 3 devices"
  /// would ellipsize into "Confirmed by 3 devi...", which reads as a bug.
  static String _confirmText(HazardReport r) => r.confirmationCount <= 1
      ? 'Reported once'
      : '${r.confirmationCount} devices confirm';

  static String _distance(double m) => m < 1000
      ? '${m.round()} m away'
      : '${(m / 1000).toStringAsFixed(1)} km away';

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Seen just now';
    if (d.inMinutes < 60) return 'Seen ${d.inMinutes} min ago';
    if (d.inHours < 24) return 'Seen ${d.inHours} h ago';
    if (d.inDays < 7) return 'Seen ${d.inDays} d ago';
    return 'Seen ${DateFormat('d MMM').format(t)}';
  }
}

/// The pointer triangle.
///
/// Drawn rather than composed from a rotated square so its border matches the
/// card's on exactly two sides and is absent on the third, where the triangle
/// meets the card. A rotated bordered box would draw a line across the join.
class _Tail extends StatelessWidget {
  const _Tail({
    required this.color,
    required this.border,
    required this.pointsDown,
    required this.fraction,
  });

  final Color color;
  final Color border;
  final bool pointsDown;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: PinPopup.cardWidth,
      height: PinPopup.tailHeight,
      child: CustomPaint(
        painter: _TailPainter(
          color: color,
          border: border,
          pointsDown: pointsDown,
          fraction: fraction,
        ),
      ),
    );
  }
}

class _TailPainter extends CustomPainter {
  _TailPainter({
    required this.color,
    required this.border,
    required this.pointsDown,
    required this.fraction,
  });

  final Color color;
  final Color border;
  final bool pointsDown;
  final double fraction;

  static const double halfWidth = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Kept clear of the rounded corners, or the tail would sprout from thin
    // air where the card's own edge has already curved away.
    final cx = (fraction * size.width).clamp(18.0, size.width - 18.0);
    final baseY = pointsDown ? 0.0 : size.height;
    final tipY = pointsDown ? size.height : 0.0;

    final path = Path()
      ..moveTo(cx - halfWidth, baseY)
      ..lineTo(cx, tipY)
      ..lineTo(cx + halfWidth, baseY);

    canvas.drawPath(path..close(), Paint()..color = color);

    // Only the two sloping edges: the base is where the card is.
    canvas.drawPath(
      Path()
        ..moveTo(cx - halfWidth, baseY)
        ..lineTo(cx, tipY)
        ..lineTo(cx + halfWidth, baseY),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.color != color ||
      old.border != border ||
      old.pointsDown != pointsDown ||
      old.fraction != fraction;
}
