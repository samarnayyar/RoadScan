import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/detection.dart';
import '../models/hazard_report.dart';

/// At-a-glance counts for the area currently loaded.
///
/// Counts are derived from the same cached pin list the map draws, so the
/// header can never disagree with what's on screen.
class StatsOverlay extends StatelessWidget {
  const StatsOverlay({
    super.key,
    required this.reports,
    required this.loading,
    required this.onRefresh,
    required this.areaName,
    required this.onSwitchArea,
  });

  final List<HazardReport> reports;
  final bool loading;
  final Future<void> Function() onRefresh;
  final String areaName;
  final VoidCallback onSwitchArea;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    // Fixed pins stay on the map (they're useful history) but shouldn't inflate
    // the "active problems" count the viewer reads as the headline number.
    final active = reports.where((r) => !r.isFixed).toList();
    final critical =
        active.where((r) => r.severity == SeverityClass.critical).length;
    final high = active.where((r) => r.severity == SeverityClass.high).length;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14),
        // Floats on the map, so it takes the map-contrasting outline too --
        // see RoadScanColors.chromeBorder.
        border: Border.all(color: c.chromeBorder, width: 1.0),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.travel_explore, size: 20, color: c.textPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tapping the area name goes back to the picker.
                InkWell(
                  onTap: onSwitchArea,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        areaName,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: c.textPrimary),
                      ),
                      const SizedBox(width: 3),
                      Icon(Icons.expand_more, size: 16, color: c.textSecondary),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${active.length} active  -  $high high  -  $critical critical',
                  style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: loading ? null : onRefresh,
            icon: loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.refresh, size: 20, color: c.textSecondary),
            tooltip: 'Refresh pins',
          ),
        ],
      ),
    );
  }
}
