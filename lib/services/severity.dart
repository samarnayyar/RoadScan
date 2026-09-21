import 'dart:math' as math;

import '../models/detection.dart';

/// The severity assessment for one photo.
class SeverityResult {
  const SeverityResult({
    required this.score,
    required this.severity,
    required this.hazard,
    required this.driver,
    required this.detections,
  });

  final double score;
  final SeverityClass severity;
  final HazardClass hazard;

  /// The single detection the score came from, kept so the review screen can
  /// highlight which box drove the verdict.
  final Detection? driver;

  final List<Detection> detections;

  bool get isEmpty => detections.isEmpty;
}

/// Severity scoring.
///
/// No public dataset labels Indian road damage by severity, and none exists for
/// the Bidholi/Kandholi/Pondha hill roads at all, so there is nothing to
/// regress against. We use the fraction of the frame the defect occupies as a
/// geometric proxy: a bigger hole in frame is a bigger hole in the road.
///
/// State this plainly in the report -- it is a deliberate, documented design
/// decision under a data constraint, not an oversight. Its known weakness is
/// scale: the same pothole shot from 1m and from 5m yields different areas.
/// Mitigations worth naming in the viva (none implemented here): normalising by
/// a reference object, using the phone's accelerometer-derived camera height,
/// or ARCore depth.
class Severity {
  Severity._();

  // Band edges as fractions of frame area, from the project brief.
  static const double _lowMax = 0.02;
  static const double _mediumMax = 0.08;
  static const double _highMax = 0.20;

  /// Above this the score is pinned at 1.0. A defect filling half the frame is
  /// already as bad as this proxy can express; without the cap, scores would
  /// crawl toward 1.0 only for a box covering the entire image.
  static const double _criticalSaturation = 0.50;

  // Score sub-ranges each band maps onto.
  static const double _lowLo = 0.10, _lowHi = 0.25;
  static const double _medLo = 0.26, _medHi = 0.55;
  static const double _highLo = 0.56, _highHi = 0.80;
  static const double _critLo = 0.81, _critHi = 1.00;

  /// Maps frame-area fraction to a 0..1 score, interpolating *within* each band
  /// rather than returning a flat value per band. Without interpolation every
  /// medium pothole would score an identical 0.26 and the map would lose all
  /// gradation between "annoying" and "nearly high".
  static double scoreForArea(double areaRatio) {
    final r = areaRatio.clamp(0.0, 1.0);
    if (r < _lowMax) return _lerp(r, 0.0, _lowMax, _lowLo, _lowHi);
    if (r < _mediumMax) return _lerp(r, _lowMax, _mediumMax, _medLo, _medHi);
    if (r < _highMax) return _lerp(r, _mediumMax, _highMax, _highLo, _highHi);
    return _lerp(r, _highMax, _criticalSaturation, _critLo, _critHi);
  }

  /// Derives the band from the final score.
  ///
  /// Order matters here: the crack multiplier is applied to the score and the
  /// class is read back off the *discounted* score. Classifying from raw area
  /// first would let a crack be labelled "high" while carrying a 0.48 score
  /// that sits in the medium range -- the badge and the colour would disagree.
  static SeverityClass classify(double score) {
    if (score < _medLo) return SeverityClass.low;
    if (score < _highLo) return SeverityClass.medium;
    if (score < _critLo) return SeverityClass.high;
    return SeverityClass.critical;
  }

  /// Scores one detection, applying the per-class multiplier.
  static double scoreForDetection(Detection d) =>
      (scoreForArea(d.areaRatio) * d.hazard.severityMultiplier).clamp(0.0, 1.0);

  /// Reduces a whole photo to a single verdict.
  ///
  /// Takes the worst single detection rather than summing areas. Summing would
  /// let a mesh of hairline cracks outscore one axle-breaking pothole, which
  /// inverts what a rider actually needs warning about. It also degrades
  /// gracefully when the model emits overlapping boxes for one defect.
  static SeverityResult assess(List<Detection> detections) {
    if (detections.isEmpty) {
      return const SeverityResult(
        score: 0.0,
        severity: SeverityClass.low,
        hazard: HazardClass.pothole,
        driver: null,
        detections: [],
      );
    }

    Detection worst = detections.first;
    double worstScore = scoreForDetection(worst);
    for (final d in detections.skip(1)) {
      final s = scoreForDetection(d);
      if (s > worstScore) {
        worstScore = s;
        worst = d;
      }
    }

    return SeverityResult(
      score: worstScore,
      severity: classify(worstScore),
      hazard: worst.hazard,
      driver: worst,
      detections: detections,
    );
  }

  /// Current confidence of a pin under exponential decay.
  ///
  /// Mirrors current_confidence() in supabase/schema.sql. The server value is
  /// authoritative; this exists so cached pins still age correctly while the
  /// phone is offline.
  static double decayedConfidence({
    required double base,
    required DateTime lastConfirmedAt,
    double lambda = 0.05,
    DateTime? now,
  }) {
    final elapsed = (now ?? DateTime.now()).difference(lastConfirmedAt);
    final days = math.max(0.0, elapsed.inSeconds / 86400.0);
    return (base * math.exp(-lambda * days)).clamp(0.0, 1.0);
  }

  static double _lerp(
    double v,
    double inLo,
    double inHi,
    double outLo,
    double outHi,
  ) {
    if (inHi <= inLo) return outLo;
    final t = ((v - inLo) / (inHi - inLo)).clamp(0.0, 1.0);
    return outLo + t * (outHi - outLo);
  }
}
