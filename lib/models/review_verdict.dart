import '../config/app_config.dart';
import 'detection.dart';

/// What the app should do with a photo the user is trying to submit.
///
/// This exists because "did the model see damage?" is not a yes/no question,
/// and treating it as one is what makes an upload gate either useless or
/// unfair. The detector's confidence is a continuum, and the app has two
/// separate decisions to make on it:
///
///   * file this report without bothering the user -- wants high PRECISION,
///     because a false positive puts a hazard on the map that is not there and
///     nobody will ever correct it;
///   * decide whether this photo is worth accepting at all -- wants RECALL,
///     because throwing away a real report is worse than one extra tap.
///
/// A single threshold cannot serve both. These are the measured operating
/// points: see the table in AppConfig.
enum ReviewVerdict {
  /// Confident damage. File it.
  accept,

  /// Something is there, but not confidently enough to file unchallenged.
  /// Show the boxes and ask the user to confirm.
  confirm,

  /// Nothing above the noise floor. Reject, and offer manual review.
  ///
  /// Note what this genuinely cannot distinguish: a photo of a ceiling, a
  /// perfectly good road, and a badly broken road the model simply failed to
  /// recognise all produce zero detections. The first two are correct
  /// rejections. The third is a real report being discarded, and no threshold
  /// anywhere fixes it -- which is precisely why the manual-review escalation
  /// is not optional.
  reject,
}

extension ReviewVerdictX on ReviewVerdict {
  bool get isAccepted => this == ReviewVerdict.accept;
  bool get needsUser => this != ReviewVerdict.accept;
}

/// Decides the verdict for a set of detections.
///
/// Judged on the STRONGEST detection, not on how many there are. Ten
/// half-certain boxes are not evidence of a pothole; they are usually one
/// ambiguous patch of shadow detected ten ways. One confident box is.
ReviewVerdict verdictFor(List<Detection> detections) {
  if (detections.isEmpty) return ReviewVerdict.reject;

  var best = ReviewVerdict.reject;
  for (final d in detections) {
    if (d.confidence < AppConfig.detectionFloor) continue;
    if (d.confidence >= AppConfig.autoAcceptFor(d.hazard)) {
      return ReviewVerdict.accept;
    }
    best = ReviewVerdict.confirm;
  }
  return best;
}

/// The detection that drove the verdict, for showing the user what was found.
Detection? strongest(List<Detection> detections) {
  Detection? top;
  for (final d in detections) {
    if (top == null || d.confidence > top.confidence) top = d;
  }
  return top;
}
