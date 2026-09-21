import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../models/detection.dart';
import '../models/hazard_report.dart';
import 'device_identity.dart';

/// Outcome of a submission -- specifically whether we created a pin or merged
/// into one, since the UI says different things for each.
class SubmitOutcome {
  const SubmitOutcome({
    required this.reportId,
    required this.wasMerged,
    required this.confirmations,
  });

  final String reportId;
  final bool wasMerged;
  final int confirmations;
}

/// Pin state immediately after a Confirm / Mark-Fixed vote.
class ConfirmOutcome {
  const ConfirmOutcome({
    required this.status,
    required this.confirmations,
    required this.negatives,
  });

  final ReportStatus status;
  final int confirmations;
  final int negatives;

  /// How many more distinct devices must report "no hazard" before the pin
  /// flips to fixed. Shown in the sheet so the vote feels like it counted.
  int get negativesRemaining =>
      (AppConfig.fixedThreshold - negatives).clamp(0, AppConfig.fixedThreshold);
}

class PhotoRecord {
  const PhotoRecord({
    required this.url,
    required this.capturedAt,
    required this.isOriginal,
    this.severityScore,
  });

  final String url;
  final DateTime capturedAt;
  final bool isOriginal;
  final double? severityScore;
}

/// All backend access. Every write goes through a Postgres function rather than
/// a table insert, because the dedup and vote-counting rules have to be
/// enforced server-side to survive concurrent reporters.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _db => Supabase.instance.client;

  static Future<void> initialise() async {
    if (!AppConfig.hasSupabaseCredentials) return;
    // `publishableKey`, not the deprecated `anonKey`. Same value either way --
    // Supabase only renamed it -- but anonKey is slated for removal in a
    // future major version.
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseKey,
    );
  }

  bool get isConfigured => AppConfig.hasSupabaseCredentials;

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<List<HazardReport>> nearby({
    required double lat,
    required double lon,
    double radiusMeters = AppConfig.pinFetchRadiusMeters,
  }) async {
    final rows = await _db.rpc('nearby_reports', params: {
      'p_lat': lat,
      'p_lon': lon,
      'p_radius_m': radiusMeters,
    }) as List<dynamic>;

    return rows
        .cast<Map<String, dynamic>>()
        .map(HazardReport.fromRpc)
        .toList(growable: false);
  }

  /// Every photo on one pin, oldest first -- the "how it changed" carousel.
  Future<List<PhotoRecord>> timeline(String reportId) async {
    final rows = await _db.rpc('report_timeline', params: {
      'p_report_id': reportId,
    }) as List<dynamic>;

    return rows.cast<Map<String, dynamic>>().map((r) {
      return PhotoRecord(
        url: publicUrl(r['storage_path'] as String),
        capturedAt: DateTime.parse(r['captured_at'] as String).toLocal(),
        isOriginal: r['is_original'] as bool? ?? false,
        severityScore: (r['severity_score'] as num?)?.toDouble(),
      );
    }).toList(growable: false);
  }

  /// Every pin, newest activity first. Backs the "All road reports" list.
  Future<List<HazardReport>> allReports({int limit = 200}) async {
    final rows = await _db.rpc('all_reports', params: {'p_limit': limit})
        as List<dynamic>;
    return rows
        .cast<Map<String, dynamic>>()
        .map(HazardReport.fromRpc)
        .toList(growable: false);
  }

  /// Pins this device reported or confirmed.
  Future<List<HazardReport>> myReports() async {
    final deviceId = await DeviceIdentity.instance.id;
    final rows = await _db.rpc('device_reports', params: {
      'p_device_id': deviceId,
    }) as List<dynamic>;
    return rows
        .cast<Map<String, dynamic>>()
        .map(HazardReport.fromRpc)
        .toList(growable: false);
  }

  String publicUrl(String storagePath) =>
      _db.storage.from(AppConfig.photoBucket).getPublicUrl(storagePath);

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Uploads the photo, then hands the whole thing to `submit_report`, which
  /// decides in one transaction whether this is a new pin or a re-confirmation
  /// of an existing one within [AppConfig.dedupRadiusMeters].
  Future<SubmitOutcome> submitReport({
    required File photo,
    required double lat,
    required double lon,
    required double severityScore,
    required SeverityClass severity,
    required HazardClass hazard,
    DateTime? capturedAt,
  }) async {
    final deviceId = await DeviceIdentity.instance.id;

    // Upload first: if storage fails we want no pin at all, rather than a pin
    // pointing at an image that was never stored.
    final storagePath = await _uploadPhoto(photo, deviceId);

    final rows = await _db.rpc('submit_report', params: {
      'p_lat': lat,
      'p_lon': lon,
      'p_severity_score': severityScore,
      'p_severity': severity.wire,
      'p_hazard': hazard.wire,
      'p_device_id': deviceId,
      'p_storage_path': storagePath,
      'p_radius_m': AppConfig.dedupRadiusMeters,
      // When the photo was actually taken, not when it was uploaded. Sent as
      // UTC so the server is never guessing at the phone's timezone.
      'p_captured_at': (capturedAt ?? DateTime.now()).toUtc().toIso8601String(),
    }) as List<dynamic>;

    if (rows.isEmpty) {
      throw StateError('submit_report returned no row');
    }
    // Keys are `out_`-prefixed: the SQL function's OUT parameters are named
    // that way so they cannot shadow the `confirmations` table or the `status`
    // column inside PL/pgSQL. See supabase/schema.sql.
    final row = rows.first as Map<String, dynamic>;
    return SubmitOutcome(
      reportId: row['out_report_id'] as String,
      wasMerged: row['out_was_merged'] as bool? ?? false,
      confirmations: (row['out_confirmations'] as num?)?.toInt() ?? 1,
    );
  }

  /// A Confirm / Mark-Fixed tap from the detail sheet.
  /// [negative] means "I was here and saw no hazard".
  ///
  /// Returns the pin's state after the vote so the sheet can update instantly
  /// instead of round-tripping the whole map.
  Future<ConfirmOutcome> confirm({
    required String reportId,
    bool negative = false,
  }) async {
    final deviceId = await DeviceIdentity.instance.id;
    final rows = await _db.rpc('confirm_report', params: {
      'p_report_id': reportId,
      'p_device_id': deviceId,
      'p_negative': negative,
    }) as List<dynamic>;

    if (rows.isEmpty) throw StateError('confirm_report returned no row');
    final row = rows.first as Map<String, dynamic>;
    return ConfirmOutcome(
      status: ReportStatus.fromWire(row['out_status'] as String? ?? 'active'),
      confirmations: (row['out_confirmations'] as num?)?.toInt() ?? 0,
      negatives: (row['out_negatives'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String> _uploadPhoto(File photo, String deviceId) async {
    final bytes = await photo.readAsBytes();
    final ext = p.extension(photo.path).replaceFirst('.', '').toLowerCase();
    final safeExt = ext.isEmpty ? 'jpg' : ext;

    // Date-partitioned so the bucket stays browsable once there are a few
    // hundred photos in it.
    final now = DateTime.now().toUtc();
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final path = '${now.year}/${_two(now.month)}/${_two(now.day)}/'
        '${deviceId.substring(0, 8)}-$stamp.$safeExt';

    await _db.storage.from(AppConfig.photoBucket).uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(
            contentType: safeExt == 'png' ? 'image/png' : 'image/jpeg',
            upsert: false,
          ),
        );
    return path;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
