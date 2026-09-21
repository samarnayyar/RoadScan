import 'package:flutter/material.dart';

import '../config/app_config.dart';
import 'detection.dart';

enum ReportStatus {
  active,
  stale,
  likelyFixed;

  static ReportStatus fromWire(String s) {
    switch (s) {
      case 'stale':
        return ReportStatus.stale;
      case 'likely_fixed':
        return ReportStatus.likelyFixed;
      default:
        return ReportStatus.active;
    }
  }

  String get label => switch (this) {
        ReportStatus.active => 'Active',
        ReportStatus.stale => 'Unverified recently',
        ReportStatus.likelyFixed => 'Likely fixed',
      };
}

/// A hazard pin as returned by the `nearby_reports` RPC.
class HazardReport {
  const HazardReport({
    required this.id,
    required this.lat,
    required this.lon,
    required this.severityScore,
    required this.severity,
    required this.hazard,
    required this.confidence,
    required this.confirmationCount,
    required this.status,
    required this.createdAt,
    required this.lastConfirmedAt,
    this.riskLevel,
    this.distanceMeters,
    this.latestPhotoPath,
    this.photoCount = 1,
  });

  final String id;
  final double lat;
  final double lon;
  final double severityScore;
  final SeverityClass severity;
  final HazardClass hazard;

  /// Already decayed server-side by `current_confidence()`.
  final double confidence;

  final int confirmationCount;
  final ReportStatus status;
  final DateTime createdAt;
  final DateTime lastConfirmedAt;
  final String? riskLevel;
  final double? distanceMeters;
  final String? latestPhotoPath;

  /// How many photos are attached. Drives the history badge in the list.
  final int photoCount;

  bool get isFresh =>
      DateTime.now().difference(createdAt) < AppConfig.freshWindow;

  bool get isStale => status == ReportStatus.stale;

  bool get isFixed => status == ReportStatus.likelyFixed;

  /// Whether this pin should be allowed to interrupt the user. Fixed pins never
  /// alert; a pin nobody has re-confirmed in weeks shouldn't either, or the
  /// alert stops meaning anything.
  bool get shouldAlert =>
      severity.isAlertWorthy && !isFixed && confidence >= 0.3;

  factory HazardReport.fromRpc(Map<String, dynamic> row) {
    double num2d(Object? v) => (v as num?)?.toDouble() ?? 0.0;

    return HazardReport(
      id: row['id'] as String,
      lat: num2d(row['lat']),
      lon: num2d(row['lon']),
      severityScore: num2d(row['severity_score']),
      severity: SeverityClass.fromWire(row['severity'] as String? ?? 'low'),
      hazard: HazardClass.fromLabel(row['hazard'] as String? ?? 'pothole') ??
          HazardClass.pothole,
      confidence: num2d(row['confidence']),
      confirmationCount: (row['confirmation_count'] as num?)?.toInt() ?? 1,
      status: ReportStatus.fromWire(row['status'] as String? ?? 'active'),
      createdAt:
          DateTime.parse(row['created_at'] as String).toLocal(),
      lastConfirmedAt:
          DateTime.parse(row['last_confirmed_at'] as String).toLocal(),
      riskLevel: row['risk_level'] as String?,
      distanceMeters: row['distance_m'] == null ? null : num2d(row['distance_m']),
      latestPhotoPath: row['latest_photo'] as String?,
      // Absent from nearby_reports, present in the list RPCs.
      photoCount: (row['photo_count'] as num?)?.toInt() ?? 1,
    );
  }

  /// Map pin colour. Severity drives hue; confidence drives opacity, applied at
  /// render time so a decaying pin visibly fades rather than vanishing.
  Color get color => switch (severity) {
        SeverityClass.low => const Color(0xFF3FA34D),
        SeverityClass.medium => const Color(0xFFE8B21A),
        SeverityClass.high => const Color(0xFFE2661C),
        SeverityClass.critical => const Color(0xFFD32F2F),
      };

  /// Never fully transparent -- a pin at 0.05 confidence is still a pin someone
  /// should be able to tap and re-confirm.
  double get markerOpacity => isFixed ? 0.35 : (0.35 + 0.65 * confidence);
}
