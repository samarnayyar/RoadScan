import 'dart:math' as math;

/// What kind of road damage a box describes.
enum HazardClass {
  pothole,
  crack;

  String get wire => name;

  /// Cracks are narrower than potholes, so an equal-area crack is a less
  /// severe defect to drive over -- but still structurally significant, hence
  /// a discount rather than exclusion.
  double get severityMultiplier => this == HazardClass.crack ? 0.85 : 1.0;

  String get label => this == HazardClass.pothole ? 'Pothole' : 'Crack';

  /// Maps a model's class label onto our two classes. Label strings vary with
  /// how the dataset was annotated ("pothole", "Pothole", "pot-hole",
  /// "longitudinal_crack", ...), so match loosely rather than exactly.
  static HazardClass? fromLabel(String raw) {
    final s = raw.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');
    if (s.contains('pothole') || s.contains('pot')) return HazardClass.pothole;
    if (s.contains('crack') || s.contains('crazing') || s.contains('alligator')) {
      return HazardClass.crack;
    }
    return null;
  }
}

enum SeverityClass {
  low,
  medium,
  high,
  critical;

  String get wire => name;

  /// True for the severities that are worth interrupting someone over.
  bool get isAlertWorthy =>
      this == SeverityClass.high || this == SeverityClass.critical;

  static SeverityClass fromWire(String s) => SeverityClass.values.firstWhere(
        (e) => e.name == s,
        orElse: () => SeverityClass.low,
      );
}

/// One box from the detector, with coordinates always normalised to 0..1 of the
/// source image regardless of what the plugin handed us.
class Detection {
  const Detection({
    required this.hazard,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final HazardClass hazard;
  final double confidence;

  /// Normalised 0..1, origin top-left.
  final double left, top, right, bottom;

  double get width => math.max(0.0, right - left);
  double get height => math.max(0.0, bottom - top);

  /// Fraction of the frame this box covers. The severity proxy.
  double get areaRatio => (width * height).clamp(0.0, 1.0);

  @override
  String toString() =>
      'Detection(${hazard.name}, conf=${confidence.toStringAsFixed(2)}, '
      'area=${areaRatio.toStringAsFixed(4)})';
}
