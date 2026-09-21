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
    final accent = critical ? const Color(0xFFD32F2F) : const Color(0xFFE2661C);

    return Dismissible(
      key: ValueKey('alert-${report.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismiss(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF15202B),
              borderRadius: BorderRadius.circular(14),
              // Thick left bar: the eye lands on the severity colour before it
              // reads any text.
              border: Border(left: BorderSide(color: accent, width: 6)),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 16,
                    offset: Offset(0, 4)),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: accent, size: 17),
                          const SizedBox(width: 5),
                          Text(
                            distanceLabel(distanceMeters).toUpperCase(),
                            style: TextStyle(
                              color: accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        critical
                            ? 'Severe ${report.hazard.label.toLowerCase()} ahead'
                            : '${report.hazard.label} ahead',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${report.severity.name} severity  -  '
                        '${report.confirmationCount} report'
                        '${report.confirmationCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Color(0xFF8FA3B5),
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (thumbnailUrl != null) ...[
                  const SizedBox(width: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      thumbnailUrl!,
                      width: 58,
                      height: 58,
                      fit: BoxFit.cover,
                      // A broken image must never blank the warning, so fall
                      // back to a plain tile rather than an error widget.
                      errorBuilder: (_, __, ___) => Container(
                        width: 58,
                        height: 58,
                        color: const Color(0xFF22394D),
                        child: const Icon(Icons.image_not_supported_outlined,
                            size: 18, color: Color(0xFF5E7386)),
                      ),
                    ),
                  ),
                ],
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close,
                      size: 18, color: Color(0xFF5E7386)),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Dismiss',
                ),
              ],
            ),
          ),
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
