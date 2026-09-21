import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:roadscan/models/detection.dart';
import 'package:roadscan/services/severity.dart';

/// A square detection covering exactly [areaRatio] of the frame.
Detection box({
  required double areaRatio,
  HazardClass hazard = HazardClass.pothole,
  double confidence = 0.9,
}) {
  final side = areaRatio <= 0 ? 0.0 : math.sqrt(areaRatio);
  return Detection(
    hazard: hazard,
    confidence: confidence,
    left: 0,
    top: 0,
    right: side,
    bottom: side,
  );
}

void main() {
  group('band boundaries', () {
    test('area fractions land in the band the brief specifies', () {
      expect(Severity.classify(Severity.scoreForArea(0.005)), SeverityClass.low);
      expect(Severity.classify(Severity.scoreForArea(0.05)), SeverityClass.medium);
      expect(Severity.classify(Severity.scoreForArea(0.12)), SeverityClass.high);
      expect(
          Severity.classify(Severity.scoreForArea(0.30)), SeverityClass.critical);
    });

    test('scores stay inside their published sub-ranges', () {
      expect(Severity.scoreForArea(0.0), closeTo(0.10, 0.001));
      expect(Severity.scoreForArea(0.019), lessThan(0.26));
      expect(Severity.scoreForArea(0.021), greaterThanOrEqualTo(0.26));
      expect(Severity.scoreForArea(0.079), lessThan(0.56));
      expect(Severity.scoreForArea(0.081), greaterThanOrEqualTo(0.56));
      expect(Severity.scoreForArea(0.199), lessThan(0.81));
      expect(Severity.scoreForArea(0.201), greaterThanOrEqualTo(0.81));
    });

    test('saturates at 1.0 rather than needing a full-frame box', () {
      expect(Severity.scoreForArea(0.50), closeTo(1.0, 0.001));
      expect(Severity.scoreForArea(0.95), closeTo(1.0, 0.001));
      expect(Severity.scoreForArea(1.0), closeTo(1.0, 0.001));
    });

    test('interpolates within a band instead of returning a flat value', () {
      final small = Severity.scoreForArea(0.03);
      final large = Severity.scoreForArea(0.07);
      expect(large, greaterThan(small));
      expect(Severity.classify(small), SeverityClass.medium);
      expect(Severity.classify(large), SeverityClass.medium);
    });

    test('is monotonic in area', () {
      double previous = -1;
      for (var a = 0.0; a <= 1.0; a += 0.01) {
        final s = Severity.scoreForArea(a);
        expect(s, greaterThanOrEqualTo(previous));
        previous = s;
      }
    });
  });

  group('crack discount', () {
    test('a crack scores 0.85x an equal-area pothole', () {
      final pothole = Severity.scoreForDetection(box(areaRatio: 0.10));
      final crack =
          Severity.scoreForDetection(box(areaRatio: 0.10, hazard: HazardClass.crack));
      expect(crack, closeTo(pothole * 0.85, 1e-9));
    });

    test('class is read off the discounted score, so badge and colour agree',
        () {
      // Area 0.085 is "high" by raw area, but the crack discount pulls the
      // score back into the medium range. The reported class must follow the
      // score, not the raw area, or the pin's label contradicts its colour.
      final crack =
          box(areaRatio: 0.085, hazard: HazardClass.crack);
      final score = Severity.scoreForDetection(crack);
      final result = Severity.assess([crack]);

      expect(result.score, closeTo(score, 1e-9));
      expect(result.severity, Severity.classify(score));
      expect(result.severity, SeverityClass.medium);
    });
  });

  group('assess', () {
    test('empty detections produce an empty, non-throwing result', () {
      final r = Severity.assess([]);
      expect(r.isEmpty, isTrue);
      expect(r.score, 0.0);
      expect(r.driver, isNull);
    });

    test('takes the worst detection, not the first or the sum', () {
      final r = Severity.assess([
        box(areaRatio: 0.01),
        box(areaRatio: 0.25),
        box(areaRatio: 0.03),
      ]);
      expect(r.severity, SeverityClass.critical);
      expect(r.driver, isNotNull);
      expect(r.driver!.areaRatio, closeTo(0.25, 0.001));
    });

    test('one big pothole outranks many small cracks', () {
      final manyCracks = [
        for (var i = 0; i < 8; i++)
          box(areaRatio: 0.015, hazard: HazardClass.crack),
      ];
      final onePothole = box(areaRatio: 0.22);

      final cracksOnly = Severity.assess(manyCracks);
      final withPothole = Severity.assess([...manyCracks, onePothole]);

      expect(cracksOnly.severity, SeverityClass.low);
      expect(withPothole.severity, SeverityClass.critical);
      expect(withPothole.hazard, HazardClass.pothole);
    });

    test('reports the hazard class of the driving detection', () {
      final r = Severity.assess([
        box(areaRatio: 0.30, hazard: HazardClass.crack),
        box(areaRatio: 0.02),
      ]);
      expect(r.hazard, HazardClass.crack);
    });
  });

  group('confidence decay', () {
    final anchor = DateTime(2026, 1, 1, 12);

    test('is 1.0 at the moment of confirmation', () {
      expect(
        Severity.decayedConfidence(base: 1.0, lastConfirmedAt: anchor, now: anchor),
        closeTo(1.0, 1e-9),
      );
    });

    test('matches e^(-0.05 * days) at the documented checkpoints', () {
      double at(int days) => Severity.decayedConfidence(
            base: 1.0,
            lastConfirmedAt: anchor,
            now: anchor.add(Duration(days: days)),
          );

      // Quoted in AppConfig: ~0.61 at 10 days, ~0.22 at 30.
      expect(at(10), closeTo(0.6065, 0.001));
      expect(at(30), closeTo(0.2231, 0.001));
    });

    test('never exceeds 1.0 or drops below 0', () {
      final future = Severity.decayedConfidence(
        base: 1.0,
        lastConfirmedAt: anchor.add(const Duration(days: 5)),
        now: anchor,
      );
      expect(future, lessThanOrEqualTo(1.0));
      expect(future, greaterThanOrEqualTo(0.0));

      final ancient = Severity.decayedConfidence(
        base: 1.0,
        lastConfirmedAt: anchor,
        now: anchor.add(const Duration(days: 4000)),
      );
      expect(ancient, greaterThanOrEqualTo(0.0));
    });

    test('decays proportionally from a reduced base', () {
      final full = Severity.decayedConfidence(
        base: 1.0,
        lastConfirmedAt: anchor,
        now: anchor.add(const Duration(days: 12)),
      );
      final half = Severity.decayedConfidence(
        base: 0.5,
        lastConfirmedAt: anchor,
        now: anchor.add(const Duration(days: 12)),
      );
      expect(half, closeTo(full * 0.5, 1e-9));
    });
  });

  group('hazard label matching', () {
    test('maps the annotation spellings a dataset is likely to use', () {
      for (final s in ['pothole', 'Pothole', 'POT_HOLE', 'pot-hole']) {
        expect(HazardClass.fromLabel(s), HazardClass.pothole, reason: s);
      }
      for (final s in [
        'crack',
        'Longitudinal_Crack',
        'alligator crack',
        'crazing',
      ]) {
        expect(HazardClass.fromLabel(s), HazardClass.crack, reason: s);
      }
    });

    test('returns null for classes we do not model', () {
      // Matters because the stock COCO fallback model emits these, and they
      // must not be scored as road damage.
      expect(HazardClass.fromLabel('person'), isNull);
      expect(HazardClass.fromLabel('bus'), isNull);
      expect(HazardClass.fromLabel(''), isNull);
    });
  });

  group('alerting policy', () {
    test('only high and critical are alert-worthy', () {
      expect(SeverityClass.low.isAlertWorthy, isFalse);
      expect(SeverityClass.medium.isAlertWorthy, isFalse);
      expect(SeverityClass.high.isAlertWorthy, isTrue);
      expect(SeverityClass.critical.isAlertWorthy, isTrue);
    });
  });
}
