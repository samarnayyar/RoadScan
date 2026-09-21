import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../models/detection.dart';
import '../models/hazard_report.dart';
import '../services/supabase_service.dart';

Future<void> showPinDetailSheet(
  BuildContext context, {
  required HazardReport report,
  required Future<void> Function() onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PinDetailSheet(report: report, onChanged: onChanged),
  );
}

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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            _Header(report: r),
            const SizedBox(height: 16),
            _PhotoTimeline(photos: _photos),
            const SizedBox(height: 18),
            _Facts(report: r),
            const SizedBox(height: 18),
            _RiskBlock(report: r),
            const SizedBox(height: 18),
            if (_voteMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF4FB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _voteMessage!,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF244A78)),
                ),
              ),
              const SizedBox(height: 12),
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
            const SizedBox(height: 8),
            Text(
              'A pin is marked fixed once ${AppConfig.fixedThreshold} different '
              'devices report it repaired.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(color: report.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.hazard.label} - ${report.severity.name}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                report.status.label,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        if (report.confirmationCount > 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '${report.confirmationCount} reports',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }
}

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
    return FutureBuilder<List<PhotoRecord>>(
      future: photos,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 150,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = snap.data ?? const <PhotoRecord>[];
        if (items.isEmpty) {
          return const SizedBox(
            height: 60,
            child: Center(child: Text('No photos attached.')),
          );
        }

        final fmt = DateFormat('d MMM, HH:mm');
        return SizedBox(
          height: 170,
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
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      photo.url,
                      width: 200,
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 200,
                        height: 140,
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                              ? child
                              : Container(
                                  width: 200,
                                  height: 140,
                                  color: Colors.grey.shade200,
                                  child: const Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${fmt.format(photo.capturedAt)}'
                    '${photo.isOriginal ? '  (first)' : ''}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
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

class _Facts extends StatelessWidget {
  const _Facts({required this.report});
  final HazardReport report;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    return Column(
      children: [
        _FactRow(
          label: 'Severity score',
          value: report.severityScore.toStringAsFixed(2),
        ),
        _FactRow(
          label: 'Confidence',
          value: '${(report.confidence * 100).round()}%',
          trailing: _ConfidenceBar(value: report.confidence),
        ),
        _FactRow(
          label: 'First reported',
          value: fmt.format(report.createdAt),
        ),
        _FactRow(
          label: 'Last confirmed',
          value: _relative(report.lastConfirmedAt),
        ),
        if (report.distanceMeters != null)
          _FactRow(
            label: 'Distance',
            value: '${report.distanceMeters!.round()} m away',
          ),
      ],
    );
  }

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value, this.trailing});
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: Colors.grey.shade300,
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
    final level = report.riskLevel ?? _heuristicLevel();
    final color = switch (level) {
      'high' => const Color(0xFFD32F2F),
      'moderate' => const Color(0xFFE2661C),
      _ => const Color(0xFF3FA34D),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
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
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
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
