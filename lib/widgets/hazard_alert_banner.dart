import 'package:flutter/material.dart';

import '../models/detection.dart';
import '../models/hazard_report.dart';

/// The in-app proximity warning.
///
/// The system notification still fires (see ProximityAlerts), but a heads-up
/// notification is easy to miss while riding and disappears on its own. This
/// banner is the primary channel: it slides in from the left edge, stays until
/// the hazard is behind you, and counts the distance down live.
///
/// Distance text is deliberately coarse ("In 50 m") rather than exact ("In
/// 47.3 m"). Phone GPS is 5-10 m accurate at best, so a precise-looking number
/// would be claiming precision the hardware cannot deliver.
class HazardAlertBanner extends StatelessWidget {
  const HazardAlertBanner({
    super.key,
    required this.report,
    required this.distanceMeters,
    required this.onDismiss,
    required this.onTap,
    this.thumbnailUrl,
  });

  final HazardReport report;
  final double distanceMeters;
  final VoidCallback onDismiss;
  final VoidCallback onTap;
  final String? thumbnailUrl;

  /// Rounds to a value a rider can act on.
  static String distanceLabel(double metres) {
    if (metres < 20) return 'Right ahead';
    if (metres < 100) return 'In ${(metres / 10).round() * 10} m';
    if (metres < 1000) return 'In ${(metres / 50).round() * 50} m';
    return 'In ${(metres / 100).round() / 10} km';
  }

  @override
  Widget build(BuildContext context) {
    final critical = report.severity == SeverityClass.critical;
    final accent = HazardReport.severityColor(report.severity);

    return Dismissible(
      key: ValueKey('alert-${report.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismiss(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF111C26),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent, width: 2),
              boxShadow: [
                // Tinted rather than black: the glow reads as the hazard
                // colour spilling off the card, which is what makes it catch
                // the eye in peripheral vision while the road has attention.
                BoxShadow(
                  color: accent.withValues(alpha: 0.35),
                  blurRadius: 26,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            // Dark in every theme, on purpose. This is the one element that
            // has to be read in a glance while moving, and a light card that
            // matched the map would compete with it instead of interrupting.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _distanceStrip(accent, critical),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 13),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _body(critical)),
                      if (thumbnailUrl != null) ...[
                        const SizedBox(width: 12),
                        _thumb(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The distance, given its own full-width band in the severity colour.
  ///
  /// It is the only part of this that changes second to second, and the only
  /// part that decides what the rider does next. Big enough to read without
  /// focusing on the phone.
  Widget _distanceStrip(Color accent, bool critical) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            critical
                ? Icons.dangerous_rounded
                : Icons.warning_amber_rounded,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              distanceLabel(distanceMeters).toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 34,
            height: 30,
            child: IconButton(
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 20, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(bool critical) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          critical ? 'Severe damage ahead' : 'Damage ahead',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${report.severity.name[0].toUpperCase()}'
          '${report.severity.name.substring(1)} severity  -  '
          '${report.confirmationCount} report'
          '${report.confirmationCount == 1 ? '' : 's'}',
          style: const TextStyle(color: Color(0xFF9DB2C4), fontSize: 13),
        ),
        if (report.hasFootprint) ...[
          const SizedBox(height: 3),
          Text(
            'About ${report.widthM!.toStringAsFixed(1)} m across',
            style: const TextStyle(color: Color(0xFF9DB2C4), fontSize: 13),
          ),
        ],
      ],
    );
  }

  Widget _thumb() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        thumbnailUrl!,
        width: 84,
        height: 72,
        fit: BoxFit.cover,
        // A broken image must never blank the warning, so fall back to a
        // plain tile rather than an error widget.
        errorBuilder: (_, __, ___) => Container(
          width: 84,
          height: 72,
          color: const Color(0xFF22394D),
          child: const Icon(Icons.image_not_supported_outlined,
              size: 20, color: Color(0xFF5E7386)),
        ),
      ),
    );
  }
}

/// Slides the banner in from the left edge and out again.
class AnimatedAlertSlot extends StatelessWidget {
  const AnimatedAlertSlot({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1.05, 0),
          end: Offset.zero,
        ).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }
}
