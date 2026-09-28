import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../models/detection.dart';
import '../models/hazard_report.dart';
import '../services/admin_mode.dart';
import '../services/ground_footprint.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';

Future<void> showPinDetailSheet(
  BuildContext context, {
  required HazardReport report,
  required Future<void> Function() onChanged,
}) {
  final c = context.rs;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: c.surface,
    // The sheet is a document, so it gets the full height it needs. The
    // scrim is heavier than the default because the report is meant to be
    // read, not glanced past on the way back to the map.
    barrierColor: c.scrim,
    builder: (_) => PinDetailSheet(report: report, onChanged: onChanged),
  );
}

/// The full report for one hazard.
///
/// Everything known about the defect in one scroll: what it is, how bad, where
/// exactly, when it was first seen and last confirmed, every photo attached to
/// it over time, and how much the record should be trusted. The popup on the
/// map answers "should I care"; this answers "what is actually going on here".
class PinDetailSheet extends StatefulWidget {
  const PinDetailSheet({
    super.key,
    required this.report,
    required this.onChanged,
  });

  final HazardReport report;
  final Future<void> Function() onChanged;

  @override
  State<PinDetailSheet> createState() => _PinDetailSheetState();
}

class _PinDetailSheetState extends State<PinDetailSheet> {
  late Future<List<PhotoRecord>> _photos;
  bool _voting = false;
  String? _voteMessage;

  @override
  void initState() {
    super.initState();
    _photos = SupabaseService.instance.timeline(widget.report.id);
  }

  bool _deleting = false;

  /// Asks first. A delete is irreversible and removes the report from every
  /// device, which is a different weight of action from the votes above it.
  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this report?'),
        content: const Text(
          'It is removed for everyone, along with its photos and '
          'confirmations. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await SupabaseService.instance.adminDeleteReport(widget.report.id);
      await widget.onChanged();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _voteMessage = 'Could not delete: $e';
      });
    }
  }

  Future<void> _vote({required bool negative}) async {
    setState(() {
      _voting = true;
      _voteMessage = null;
    });
    try {
      final outcome = await SupabaseService.instance.confirm(
        reportId: widget.report.id,
        negative: negative,
      );

      if (!mounted) return;
      setState(() {
        _voteMessage = switch (outcome.status) {
          ReportStatus.likelyFixed => 'Marked as likely fixed. Thanks!',
          _ when negative => 'Recorded. '
              '${outcome.negativesRemaining} more device'
              '${outcome.negativesRemaining == 1 ? '' : 's'} needed to mark '
              'this fixed.',
          _ => 'Confirmed. Now ${outcome.confirmations} reports.',
        };
      });
      await widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _voteMessage = 'Could not record that: $e');
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final c = context.rs;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      minChildSize: 0.45,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
          children: [
            _Header(report: r),
            const SizedBox(height: 18),
            _SummaryLine(report: r),
            const SizedBox(height: 18),
            _Section(label: 'Photos', child: _PhotoTimeline(photos: _photos)),
            const SizedBox(height: 20),
            _Section(label: 'When', child: _WhenBlock(report: r)),
            const SizedBox(height: 20),
            _Section(label: 'Where', child: _WhereBlock(report: r)),
            const SizedBox(height: 20),
            _Section(label: 'Measurements', child: _MeasureBlock(report: r)),
            const SizedBox(height: 20),
            _Section(label: 'Risk', child: _RiskBlock(report: r)),
            const SizedBox(height: 22),
            if (_voteMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  _voteMessage!,
                  style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _voting || r.isFixed
                        ? null
                        : () => _vote(negative: false),
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Still there'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _voting || r.isFixed ? null : () => _vote(negative: true),
                    icon: const Icon(Icons.done_all, size: 18),
                    label: const Text('Looks fixed'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'A pin is marked fixed once ${AppConfig.fixedThreshold} different '
              'devices report it repaired.',
              style: TextStyle(fontSize: 11.5, color: c.textMuted),
            ),
            const SizedBox(height: 14),
            // The record's own identity, last and quietest. Useful when
            // comparing what two phones are showing for the same defect.
            _IdRow(id: r.id),

            // Admin only, and absent entirely otherwise -- this removes the
            // report for every device, so it must not be one stray tap away
            // for an ordinary user.
            ValueListenableBuilder<bool>(
              valueListenable: AdminMode.instance.enabled,
              builder: (context, admin, _) {
                if (!admin || !AppConfig.hasAdminToken) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: OutlinedButton.icon(
                    onPressed: _deleting ? null : _confirmDelete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD32F2F),
                      side: const BorderSide(color: Color(0x55D32F2F)),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(_deleting ? 'Deleting...' : 'Delete report'),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Header + one-line summary
// -----------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: report.color,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            report.severity.name.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                report.hazard.label,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                report.status.label,
                style: TextStyle(fontSize: 12.5, color: c.textMuted),
              ),
            ],
          ),
        ),
        if (report.confirmationCount > 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: Text(
              '${report.confirmationCount} reports',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: c.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

/// A plain-English sentence covering the whole record.
///
/// The tables below hold every field, but a table is something you search, not
/// something you read. This is the one line a user can take away.
class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final r = report;
    final near = _nearest(r);
    final size = r.hasFootprint
        ? ' roughly ${r.widthM!.toStringAsFixed(1)} m across,'
        : '';

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: c.border),
      ),
      child: Text(
        'A ${r.severity.name} ${r.hazard.label.toLowerCase()},$size '
        'first reported ${_absolute(r.createdAt)} near ${near.name}. '
        '${_confirmSentence(r)} '
        'Last seen ${_relative(r.lastConfirmedAt)}.',
        style: TextStyle(fontSize: 13.5, height: 1.45, color: c.textSecondary),
      ),
    );
  }

  static String _confirmSentence(HazardReport r) => r.confirmationCount <= 1
      ? 'No other device has confirmed it yet.'
      : '${r.confirmationCount} devices have reported it.';
}

// -----------------------------------------------------------------------------
// Sections
// -----------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.0,
            color: c.textMuted,
          ),
        ),
        const SizedBox(height: 9),
        child,
      ],
    );
  }
}

class _WhenBlock extends StatelessWidget {
  const _WhenBlock({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return Column(
      children: [
        _FactRow(
          label: 'First reported',
          value: _absoluteFull(r.createdAt),
          sub: _relative(r.createdAt),
        ),
        _FactRow(
          label: 'Last confirmed',
          value: _absoluteFull(r.lastConfirmedAt),
          sub: _relative(r.lastConfirmedAt),
        ),
        _FactRow(
          label: 'Tracked for',
          value: _span(DateTime.now().difference(r.createdAt)),
        ),
      ],
    );
  }

  static String _span(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
    if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    return '${d.inMinutes} min';
  }
}

class _WhereBlock extends StatelessWidget {
  const _WhereBlock({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final near = _nearest(r);
    final away = LocationService.distanceMeters(
      r.lat,
      r.lon,
      near.center.latitude,
      near.center.longitude,
    );

    return Column(
      children: [
        _FactRow(
          label: 'Nearest landmark',
          value: near.name,
          sub: '${_metres(away)} away - ${near.subtitle}',
        ),
        if (r.distanceMeters != null)
          _FactRow(
            label: 'From you',
            value: _metres(r.distanceMeters!),
          ),
        // Coordinates last and copyable: nobody reads a lat/lon, but somebody
        // filing this with the municipality needs to paste it somewhere.
        _FactRow(
          label: 'Coordinates',
          value: '${r.lat.toStringAsFixed(6)}, ${r.lon.toStringAsFixed(6)}',
          copyable: true,
        ),
      ],
    );
  }
}

class _MeasureBlock extends StatelessWidget {
  const _MeasureBlock({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final r = report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FactRow(
          label: 'Detector score',
          value: '${AppConfig.displayConfidence(r.severityScore)}%',
          sub: 'how sure the model was this is damage',
        ),
        _FactRow(
          label: 'Record confidence',
          value: '${(r.confidence * 100).round()}%',
          trailing: _ConfidenceBar(value: r.confidence),
          sub: 'decays over time unless re-confirmed',
        ),
        if (r.hasFootprint)
          _FactRow(
            label: 'Estimated size',
            value: '${r.widthM!.toStringAsFixed(2)} m wide x '
                '${r.lengthM!.toStringAsFixed(2)} m long',
            sub: 'from camera geometry, not a measurement',
          )
        else
          _FactRow(
            label: 'Estimated size',
            value: 'Not available',
            sub: 'the photo geometry could not be trusted',
          ),
        const SizedBox(height: 6),
        Text(
          'Size is projected from the photo assuming a phone held about '
          '${GroundFootprint.cameraHeightM} m above a flat road. Treat it as a '
          'rough scale, not a survey.',
          style: TextStyle(fontSize: 11.5, height: 1.35, color: c.textMuted),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Photos
// -----------------------------------------------------------------------------

/// The photo carousel.
///
/// Every re-confirmation within the dedup radius attaches its photo to the same
/// pin, so this is a chronological record of one defect -- how it widened over
/// a monsoon, or that it was patched. This is what "overlaid on each other" in
/// the brief means in practice: one pin, many photos over time, not image
/// blending.
class _PhotoTimeline extends StatelessWidget {
  const _PhotoTimeline({required this.photos});
  final Future<List<PhotoRecord>> photos;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return FutureBuilder<List<PhotoRecord>>(
      future: photos,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 180,
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            ),
          );
        }
        final items = snap.data ?? const <PhotoRecord>[];
        if (items.isEmpty) {
          return SizedBox(
            height: 60,
            child: Center(
              child: Text(
                'No photos attached.',
                style: TextStyle(color: c.textMuted, fontSize: 12.5),
              ),
            ),
          );
        }

        final fmt = DateFormat('d MMM, HH:mm');
        return SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final photo = items[i];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.network(
                      photo.url,
                      width: 232,
                      height: 164,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 232,
                        height: 164,
                        color: c.surfaceAlt,
                        child: Icon(Icons.broken_image_outlined,
                            color: c.textMuted),
                      ),
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                              ? child
                              : Container(
                                  width: 232,
                                  height: 164,
                                  color: c.surfaceAlt,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: c.textMuted,
                                    ),
                                  ),
                                ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${fmt.format(photo.capturedAt)}'
                    '${photo.isOriginal ? '  (first)' : ''}',
                    style: TextStyle(fontSize: 11, color: c.textMuted),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Rows
// -----------------------------------------------------------------------------

class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.value,
    this.sub,
    this.trailing,
    this.copyable = false,
  });

  final String label;
  final String value;
  final String? sub;
  final Widget? trailing;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(
                label,
                style: TextStyle(fontSize: 12.5, color: c.textMuted),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (copyable)
              Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(left: 132, top: 2),
            child: Text(
              sub!,
              style: TextStyle(fontSize: 11.5, color: c.textMuted),
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: copyable
          ? InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Coordinates copied'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(6),
              child: body,
            )
          : body,
    );
  }
}

class _IdRow extends StatelessWidget {
  const _IdRow({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Row(
      children: [
        Icon(Icons.tag, size: 13, color: c.textMuted),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            'Report $id',
            style: TextStyle(fontSize: 10.5, color: c.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return SizedBox(
      width: 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: c.surfaceAlt,
          color: c.accent,
        ),
      ),
    );
  }
}

/// Accident-risk readout.
///
/// The risk model and its SHAP explanation live in a small Python service
/// (phase 5 of the build plan) and are not wired up yet, so this renders a
/// locally-derived placeholder rather than inventing a number. Once the service
/// is running, `report.riskLevel` is populated server-side and the plain-
/// language explanation replaces the note below.
class _RiskBlock extends StatelessWidget {
  const _RiskBlock({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    final level = report.riskLevel ?? _heuristicLevel();
    final color = switch (level) {
      'high' => const Color(0xFFD32F2F),
      'moderate' => const Color(0xFFE2661C),
      _ => const Color(0xFF3FA34D),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                'Accident risk: ${level.toUpperCase()}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            report.riskLevel == null
                ? 'Estimated from severity and confirmations only. The trained '
                    'risk model is not connected yet.'
                : 'Driven mainly by severity and how often this has been '
                    'confirmed.',
            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  String _heuristicLevel() {
    if (report.severity == SeverityClass.critical) return 'high';
    if (report.severity == SeverityClass.high) {
      return report.confirmationCount >= 3 ? 'high' : 'moderate';
    }
    if (report.severity == SeverityClass.medium) return 'moderate';
    return 'low';
  }
}

// -----------------------------------------------------------------------------
// Shared formatting
// -----------------------------------------------------------------------------

/// The closest of the four corridor areas.
///
/// There is no reverse geocoder in this build and adding one would mean a
/// network call and a key for something the corridor does not need: four known
/// landmarks cover every point inside the operating square.
CampusArea _nearest(HazardReport r) {
  var best = AppConfig.areas.first;
  var bestD = double.infinity;
  for (final a in AppConfig.areas) {
    final d = LocationService.distanceMeters(
      r.lat,
      r.lon,
      a.center.latitude,
      a.center.longitude,
    );
    if (d < bestD) {
      bestD = d;
      best = a;
    }
  }
  return best;
}

String _metres(double m) =>
    m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';

String _absolute(DateTime t) => DateFormat('d MMM').format(t);

String _absoluteFull(DateTime t) => DateFormat('d MMM yyyy, HH:mm').format(t);

String _relative(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  return '${d.inDays} days ago';
}
