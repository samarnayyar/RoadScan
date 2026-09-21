import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../models/detection.dart';
import '../services/detection_service.dart';
import '../services/location_service.dart';
import '../services/photo_metadata.dart';
import '../services/severity.dart';
import '../services/supabase_service.dart';
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
    if (detections.isEmpty) {
      return DetectionService.instance.usingFallbackModel
          ? 'No fine-tuned model bundled yet, so nothing can be detected. '
              'See ml/train_export.py.'
          : 'No pothole or crack found. Retake closer, or submit anyway if you '
              'can see damage.';
    }
    return null;
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

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
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
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(outcome.wasMerged
              ? 'Added to an existing report nearby - now confirmed by '
                  '${outcome.confirmations} devices.'
              : 'New hazard reported. Thanks!'),
          duration: const Duration(seconds: 4),
        ),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source == ImageSource.camera
            ? 'Report a hazard'
            : 'Upload a photo'),
      ),
      body: meta == null
          ? const Center(child: CircularProgressIndicator())
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: const [
          BoxShadow(
              color: Color(0x1A000000),
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

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _stage == _Stage.submitting
                        ? null
                        : () => _pick(widget.source),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(widget.source == ImageSource.camera
                        ? 'Retake'
                        : 'Pick another'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: _stage == _Stage.submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.upload_outlined, size: 18),
                    label: Text(_stage == _Stage.submitting
                        ? 'Submitting...'
                        : 'Submit report'),
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
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final subtle = TextStyle(fontSize: 11.5, color: Colors.grey.shade700);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, size: 15, color: Colors.grey.shade600),
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
        Row(
          children: [
            Icon(Icons.place_outlined, size: 15, color: Colors.grey.shade600),
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
            TextButton.icon(
              onPressed: onEditLocation,
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              label: Text(meta.hasLocation ? 'Adjust' : 'Set location'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
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
          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
        ),
      ],
    );
  }
}

enum _Tone { info, error }

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.tone});
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final isError = tone == _Tone.error;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFDECEA) : const Color(0xFFEFF4FB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isError ? const Color(0xFF8C2F26) : const Color(0xFF244A78),
        ),
      ),
    );
  }
}
