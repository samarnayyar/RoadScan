import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/hazard_report.dart';
import '../services/supabase_service.dart';
import '../widgets/pin_detail_sheet.dart';

/// Incident list: every hazard, or only the ones this device contributed to.
///
/// Each row opens the pin's full photo timeline, which is the "see history /
/// all versions" view: one hazard, every photo ever attached to it, oldest
/// first, so you can watch a pothole widen over a monsoon or confirm it was
/// patched.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.mine});

  /// true = only this device's contributions.
  final bool mine;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late Future<List<HazardReport>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<HazardReport>> _load() => widget.mine
      ? SupabaseService.instance.myReports()
      : SupabaseService.instance.allReports();

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mine ? 'My reports' : 'All road reports'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<HazardReport>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Message(
                icon: Icons.cloud_off,
                title: 'Could not load reports',
                body: '${snap.error}',
              );
            }

            final items = snap.data ?? const <HazardReport>[];
            if (items.isEmpty) {
              return _Message(
                icon: Icons.inbox_outlined,
                title: widget.mine ? 'No reports yet' : 'Nothing reported yet',
                body: widget.mine
                    ? 'Hazards you report or confirm will appear here.'
                    : 'Be the first to report a hazard in this area.',
              );
            }

            return ListView.separated(
              // Always scrollable so pull-to-refresh works even on a short list.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _ReportRow(
                report: items[i],
                onTap: () => showPinDetailSheet(
                  context,
                  report: items[i],
                  onChanged: _refresh,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report, required this.onTap});

  final HazardReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = report.latestPhotoPath;
    final fmt = DateFormat('d MMM yyyy');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: thumb == null
            ? Container(
                width: 54,
                height: 54,
                color: Colors.grey.shade300,
                child: const Icon(Icons.image_not_supported_outlined, size: 20),
              )
            : Image.network(
                SupabaseService.instance.publicUrl(thumb),
                width: 54,
                height: 54,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 54,
                  height: 54,
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image_outlined, size: 20),
                ),
              ),
      ),
      title: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration:
                BoxDecoration(color: report.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            '${report.hazard.label} - ${report.severity.name}',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'First seen ${fmt.format(report.createdAt)}  -  '
              '${report.photoCount} photo${report.photoCount == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 11.5),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                _Chip(
                  label: report.status.label,
                  color: report.isFixed
                      ? const Color(0xFF3FA34D)
                      : report.isStale
                          ? const Color(0xFF8A8A8A)
                          : const Color(0xFF1B6CA8),
                ),
                const SizedBox(width: 6),
                _Chip(
                  label: '${(report.confidence * 100).round()}% confidence',
                  color: Colors.grey.shade600,
                ),
              ],
            ),
          ],
        ),
      ),
      trailing: report.photoCount > 1
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.history, size: 18, color: Color(0xFF1B6CA8)),
                Text('${report.photoCount}',
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w700)),
              ],
            )
          : const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // Inside a ListView so RefreshIndicator still has something to pull on.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(icon, size: 48, color: Colors.grey.shade400),
        const SizedBox(height: 14),
        Center(
          child: Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
          ),
        ),
      ],
    );
  }
}
