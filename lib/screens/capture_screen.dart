import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../config/app_theme.dart';
import '../services/theme_controller.dart' show AppThemeKind;
import '../models/detection.dart';
import '../models/review_verdict.dart';
import '../services/detection_service.dart';
import '../services/location_service.dart';
import '../services/photo_metadata.dart';
import '../services/severity.dart';
import '../services/supabase_service.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/detection_overlay.dart';
import 'adjust_location_screen.dart';

/// Capture or upload -> on-device detection -> review -> submit.
///
/// Detection runs locally and immediately, before any upload, so the user sees
/// boxes on their photo within a second. That instant feedback also makes a bad
/// photo obvious while they are still standing at the pothole.
///
/// Two entry points with different metadata behaviour:
///   * camera  -> time and place come from the device, right now
///   * gallery -> time and place come from the photo's EXIF, which may be days
///                old and somewhere else entirely
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.source});

  final ImageSource source;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

/// Why the capture screen closed. The map screen turns this into a message,
/// so backing out never looks like a silent failure.
enum CaptureResult { submitted, discarded, cancelled }

enum _Stage { picking, analysing, review, submitting }

class _CaptureScreenState extends State<CaptureScreen> {
  _Stage _stage = _Stage.picking;
  PhotoMetadata? _meta;
  SeverityResult? _result;
  String? _error;
  String? _notice;
  double? _gpsAccuracy;

  @override
  void initState() {
    super.initState();
    DetectionService.instance.load().catchError(
      (Object e) => debugPrint('RoadScan: model warm-up failed: $e'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick(widget.source));
  }

  // ---------------------------------------------------------------------------
  // Pick + analyse
  // ---------------------------------------------------------------------------

  Future<void> _pick(ImageSource source) async {
    setState(() {
      _error = null;
      _notice = null;
      _stage = _Stage.picking;
    });

    try {
      final meta = await PhotoMetadataService.instance.pick(source);
      if (meta == null) {
        // Backed out of the system picker / camera. If nothing was ever
        // chosen, close this screen entirely rather than stranding the user on
        // an empty grey page with no way forward but the back button.
        if (mounted && _meta == null) {
          Navigator.of(context).pop(CaptureResult.cancelled);
        } else if (mounted) {
          // They already had a photo and cancelled the re-pick: keep the old
          // one rather than throwing their work away.
          setState(() => _stage = _Stage.review);
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        _meta = meta;
        _stage = _Stage.analysing;
      });

      // If EXIF gave us nothing, fall back to the device. For a camera shot
      // that is exactly right; for an old gallery photo it is a guess, and the
      // UI labels it as such rather than passing it off as the real thing.
      await _fillMissingMetadata(meta);

      final bytes = await meta.file.readAsBytes();
      final detections = await DetectionService.instance.detect(
        bytes,
        imageWidth: meta.width,
        imageHeight: meta.height,
      );

      if (!mounted) return;
      setState(() {
        _result = Severity.assess(detections);
        _stage = _Stage.review;
        _notice = _buildNotice(meta, detections);
      });
    } on ModelLoadFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _result = Severity.assess(const []);
        _error = 'Detector unavailable: ${e.message}';
        _stage = _Stage.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not process that photo: $e';
        _stage = _Stage.review;
      });
    }
  }

  Future<void> _fillMissingMetadata(PhotoMetadata meta) async {
    if (meta.capturedAt == null) {
      meta.capturedAt = DateTime.now();
      meta.capturedAtSource = MetadataSource.live;
    }

    if (!meta.hasLocation) {
      try {
        final pos = await LocationService.instance.currentPosition();
        meta.latitude = pos.latitude;
        meta.longitude = pos.longitude;
        meta.locationSource = MetadataSource.live;
        _gpsAccuracy = pos.accuracy;
      } on LocationUnavailable {
        meta.locationSource = MetadataSource.none;
      }
    }
  }

  String? _buildNotice(PhotoMetadata meta, List<Detection> detections) {
    // Most important first: a report with no position cannot be filed at all.
    if (!meta.hasLocation) {
      return 'This photo has no location and GPS is unavailable. Tap "Set '
          'location" to place it on the map before submitting.';
    }
    if (meta.isBackdated) {
      final when = DateFormat('d MMM, HH:mm').format(meta.capturedAt!);
      return 'This photo was taken on $when. The report will be dated then, '
          'not now, so its freshness is honest.';
    }
    if (DetectionService.instance.usingFallbackModel) {
      return 'No fine-tuned model bundled yet, so nothing can be detected. '
          'See ml/train_export.py.';
    }

    switch (verdictFor(detections)) {
      case ReviewVerdict.accept:
        // Confident enough to file unchallenged; nothing to say.
        return null;

      case ReviewVerdict.confirm:
        // Deliberately names what it thinks it saw and how sure it is. "Please
        // confirm" with no evidence just trains people to tap through.
        final d = strongest(detections)!;
        final pct = (d.confidence * 100).round();
        return 'Possible ${d.hazard.label.toLowerCase()} found, but only '
            '$pct% confident. Check the box looks right before submitting, or '
            'retake closer.';

      case ReviewVerdict.reject:
        return 'No pothole or crack detected. If you can see damage the model '
            'missed, submit it for manual review and an admin will check it.';
    }
  }

  // ---------------------------------------------------------------------------
  // Location adjustment
  // ---------------------------------------------------------------------------

  Future<void> _adjustLocation() async {
    final meta = _meta;
    if (meta == null) return;

    // With no fix at all, open the map at the campus so there is something to
    // drag, rather than at (0,0) in the Gulf of Guinea.
    final start = meta.hasLocation
        ? LatLng(meta.latitude!, meta.longitude!)
        : const LatLng(30.4159, 77.9670);

    final result = await Navigator.of(context).push<AdjustedLocation>(
      MaterialPageRoute(
        builder: (_) => AdjustLocationScreen(
          initial: start,
          source: meta.locationSource,
          accuracyMeters: _gpsAccuracy,
        ),
      ),
    );

    if (result == null || !mounted) return;
    setState(() {
      meta.latitude = result.position.latitude;
      meta.longitude = result.position.longitude;
      meta.locationSource = result.source;
      _notice = _buildNotice(meta, _result?.detections ?? const []);
    });
  }

  /// Asks what the user saw, then files the report for human review.
  ///
  /// The note is not optional decoration: the reviewer is looking at a photo
  /// the model found nothing in, and without a claim to check against they
  /// have no idea what they are supposed to be judging.
  Future<void> _sendForReview() async {
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = ctx.rs;
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('Send for human review',
              style: TextStyle(color: c.textPrimary, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The detector found nothing here. Your photo, its time and '
                'its location will be sent for an admin to check. It will not '
                'appear on the map unless they confirm it.',
                style: TextStyle(color: c.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 140,
                style: TextStyle(color: c.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'What can you see?',
                  labelStyle: TextStyle(color: c.textMuted),
                  hintText: 'e.g. deep pothole, edge of the road has collapsed',
                  hintStyle: TextStyle(color: c.textMuted, fontSize: 12),
                  enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.border)),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.accent)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(foregroundColor: c.textMuted),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                  controller.text.trim().isEmpty
                      ? 'Damage reported by user; no description given.'
                      : controller.text.trim()),
              style: FilledButton.styleFrom(
                  backgroundColor: c.accent, foregroundColor: c.background),
              child: const Text('Send'),
            ),
          ],
        );
      },
    );

    if (note == null || !mounted) return;
    await _submit(reviewNote: note);
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  /// [reviewNote] non-null sends the report to the human review queue rather
  /// than straight to the map. Used when the detector found nothing and the
  /// user is asserting damage anyway.
  Future<void> _submit({String? reviewNote}) async {
    final meta = _meta;
    final result = _result;
    if (meta == null || result == null || !meta.hasLocation) return;

    if (!SupabaseService.instance.isConfigured) {
      setState(() => _error = 'Supabase is not configured, so this report '
          'cannot be uploaded.');
      return;
    }

    setState(() {
      _stage = _Stage.submitting;
      _error = null;
    });

    try {
      final outcome = await SupabaseService.instance.submitReport(
        photo: meta.file,
        lat: meta.latitude!,
        lon: meta.longitude!,
        severityScore: result.isEmpty ? 0.10 : result.score,
        severity: result.isEmpty ? SeverityClass.low : result.severity,
        hazard: result.isEmpty ? HazardClass.pothole : result.hazard,
        capturedAt: meta.capturedAt,
        reviewNote: reviewNote,
      );

      if (!mounted) return;
      showAppSnack(
        context,
        reviewNote != null
            ? 'Sent for review. It will appear on the map only once an admin '
                'confirms the damage.'
            : outcome.wasMerged
                ? 'Added to an existing report nearby - now confirmed by '
                    '${outcome.confirmations} devices.'
                : 'New hazard reported. Thanks!',
        duration: const Duration(seconds: 5),
      );
      Navigator.of(context).pop(CaptureResult.submitted);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Upload failed: $e';
        _stage = _Stage.review;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    // Hardware back pops with a null result, which the map screen treats the
    // same as an explicit cancel: nothing was uploaded. No PopScope needed --
    // intercepting back to attach a reason would only risk trapping the user
    // on this screen, and "submitted or not" is the only distinction that
    // actually changes what happens next.
    final c = context.rs;
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: c.background,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Text(widget.source == ImageSource.camera
            ? 'Report a hazard'
            : 'Upload a photo'),
      ),
      body: meta == null
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : Column(
              children: [
                Expanded(child: _buildPreview(meta)),
                _buildPanel(meta),
              ],
            ),
    );
  }

  Widget _buildPreview(PhotoMetadata meta) {
    final result = _result;
    return Container(
      color: Colors.black,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(meta.file, fit: BoxFit.contain),
          if (result != null && result.detections.isNotEmpty)
            DetectionOverlay(
              detections: result.detections,
              imageAspectRatio: meta.aspectRatio,
              driver: result.driver,
            ),
          // Said over the photo, not only in the panel below.
          //
          // The panel shows one notice at a time and location outranks
          // everything, so a missing GPS fix used to hide the fact that
          // nothing was detected at all. Those are two different problems and
          // the user needs both: the verdict belongs on the image it is a
          // verdict about.
          if (_stage == _Stage.review &&
              result != null &&
              !DetectionService.instance.usingFallbackModel &&
              verdictFor(result.detections) == ReviewVerdict.reject)
            const Center(child: _NothingFoundBadge()),

          if (_stage == _Stage.analysing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('Analysing on device...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPanel(PhotoMetadata meta) {
    final result = _result;
    final canSubmit = _stage == _Stage.review && meta.hasLocation;

    final c = context.rs;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, -2)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result != null && !result.isEmpty) ...[
              _SeverityChip(result: result),
              const SizedBox(height: 10),
            ],
            if (_notice != null) _Note(text: _notice!, tone: _Tone.info),
            if (_error != null) _Note(text: _error!, tone: _Tone.error),
            if (_notice != null || _error != null) const SizedBox(height: 8),

            _MetadataRow(meta: meta, onEditLocation: _adjustLocation),
            const SizedBox(height: 12),

            // The escape hatch for a real hazard the model missed.
            //
            // Offered only when nothing was detected, because that is the only
            // case where the app would otherwise refuse a genuine report. It
            // still requires a location -- a report nobody can find is not a
            // report -- and it files the pin as `pending`, hidden from the map
            // until an admin approves it. See 004_human_review.sql.
            if (result != null &&
                !DetectionService.instance.usingFallbackModel &&
                verdictFor(result.detections) == ReviewVerdict.reject) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: canSubmit ? _sendForReview : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textPrimary,
                    side: BorderSide(color: c.accent.withValues(alpha: 0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: const Icon(Icons.how_to_reg_outlined, size: 18),
                  label: Text(
                    meta.hasLocation
                        ? 'I can see damage - send for human review'
                        : 'Set a location first to send for review',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],

            Row(
              children: [
                // flex 3 : 4, not 1 : 2.
                //
                // At 1:2 the retake button got a third of the row, which is
                // narrower than "Retake" plus its icon at this text size -- the
                // label wrapped mid-word and rendered as "Retak / e". maxLines
                // and ellipsis below are the backstop for the longer "Pick
                // another" and for larger system font scales.
                Expanded(
                  flex: 3,
                  child: OutlinedButton.icon(
                    onPressed: _stage == _Stage.submitting
                        ? null
                        : () => _pick(widget.source),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.accent,
                      side: BorderSide(color: c.border),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      widget.source == ImageSource.camera
                          ? 'Retake'
                          : 'Pick another',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 4,
                  child: FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.background,
                      disabledBackgroundColor: c.surfaceAlt,
                      disabledForegroundColor: c.textMuted,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: _stage == _Stage.submitting
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: c.background),
                          )
                        : const Icon(Icons.upload_outlined, size: 18),
                    label: Text(
                      _stage == _Stage.submitting
                          ? 'Submitting...'
                          : 'Submit report',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows where the time and place actually came from, and lets the user fix
/// the place. Being explicit about provenance is what makes the time series
/// trustworthy rather than merely plausible.
class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.meta, required this.onEditLocation});

  final PhotoMetadata meta;
  final VoidCallback onEditLocation;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final subtle = TextStyle(fontSize: 11.5, color: c.textSecondary);
    final iconColor = c.textMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, size: 15, color: iconColor),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                meta.capturedAt == null
                    ? 'No timestamp'
                    : '${fmt.format(meta.capturedAt!)}  '
                        '(${meta.capturedAtSource.label})',
                style: subtle,
              ),
            ),
            if (meta.isBackdated)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4E5),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text(
                  'EARLIER DATE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF9A6216),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        // Coordinates on their own line, the action beneath them.
        //
        // Side by side, the coordinate string and the button competed for one
        // row: the text was squeezed into an Expanded that truncated it, while
        // "Set location" sat far right where it read as unrelated to the "No
        // location" it was offering to fix.
        Row(
          children: [
            Icon(Icons.place_outlined, size: 15, color: iconColor),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                meta.hasLocation
                    ? '${meta.latitude!.toStringAsFixed(5)}, '
                        '${meta.longitude!.toStringAsFixed(5)}  '
                        '(${meta.locationSource.label})'
                    : 'No location',
                style: subtle,
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: onEditLocation,
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              label: Text(meta.hasLocation ? 'Adjust' : 'Set location'),
              style: TextButton.styleFrom(
                foregroundColor: c.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
          ),
        ),
      ],
    );
  }
}

class _SeverityChip extends StatelessWidget {
  const _SeverityChip({required this.result});
  final SeverityResult result;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.severity) {
      SeverityClass.low => const Color(0xFF3FA34D),
      SeverityClass.medium => const Color(0xFFE8B21A),
      SeverityClass.high => const Color(0xFFE2661C),
      SeverityClass.critical => const Color(0xFFD32F2F),
    };

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${result.hazard.label} - ${result.severity.name.toUpperCase()}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'score ${result.score.toStringAsFixed(2)}  -  '
          '${result.detections.length} found',
          style: TextStyle(color: context.rs.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

enum _Tone { info, error }

/// "Nothing found", stated over the photo itself.
///
/// Semi-opaque rather than solid so the user can still see what the model was
/// looking at while reading the verdict -- being told "no pothole" over a
/// hidden photo is how people conclude the app is broken.
class _NothingFoundBadge extends StatelessWidget {
  const _NothingFoundBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 28),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, color: Colors.white, size: 26),
          SizedBox(height: 8),
          Text(
            'No pothole or crack detected',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Retake closer, or send it for a human to check',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFD7DDE4), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.tone});
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final isError = tone == _Tone.error;

    // Error keeps a fixed red pair rather than a theme colour: it has to read
    // as "something is wrong" identically in dark, light and neon, and the
    // palettes have no red of their own. The info tone follows the theme,
    // because it is ordinary guidance and a hardcoded pale blue panel looked
    // pasted on over the dark and neon backgrounds.
    final bg = isError
        ? const Color(0xFFD32F2F).withValues(alpha: 0.14)
        : c.accent.withValues(alpha: 0.12);
    final fg = isError
        ? (c.kind == AppThemeKind.light
            ? const Color(0xFF8C2F26)
            : const Color(0xFFFF9C91))
        : c.textSecondary;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError
              ? const Color(0xFFD32F2F).withValues(alpha: 0.35)
              : c.accent.withValues(alpha: 0.30),
        ),
      ),
      // 10pt, down from 12. The panel competes with the photo for a small
      // screen and the notice was taking three lines of prime space for what
      // is, at most, one instruction.
      child: Text(text, style: TextStyle(fontSize: 10, height: 1.3, color: fg)),
    );
  }
}
