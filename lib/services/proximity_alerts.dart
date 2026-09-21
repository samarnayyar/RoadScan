import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/detection.dart';
import '../models/hazard_report.dart';
import 'location_service.dart';
import 'supabase_service.dart';

/// Fires a notification when the user approaches a high or critical hazard.
///
/// Deliberately does NOT use a geofencing API. Android's geofence service caps
/// registrations (100 per app) and trades latency for battery, and Google Maps'
/// proximity features would pull in a billed dependency. Since pins for the
/// whole campus are already cached for the map, a distance check over a few
/// hundred cached points on each GPS update costs microseconds and is exact.
///
/// SCOPE NOTE for the report: this runs while the app is in the foreground.
/// Android restricts background location hard (battery optimisation, the
/// separate ACCESS_BACKGROUND_LOCATION grant, OEM killers on Xiaomi/Oppo etc.),
/// and a background service that survives across vendors is its own project.
/// Claim foreground alerting, not background.
class ProximityAlerts {
  ProximityAlerts._();
  static final ProximityAlerts instance = ProximityAlerts._();

  static const int _channelHash = 4201;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final Map<String, DateTime> _lastAlerted = {};
  bool _ready = false;

  /// Set by the UI so an alert can also surface as an in-app banner.
  void Function(HazardReport report, double distance)? onAlert;

  Future<void> initialise() async {
    if (_ready) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
    );

    // High importance: a road hazard warning is only useful if it interrupts.
    const channel = AndroidNotificationChannel(
      'roadscan_hazards',
      'Road hazard alerts',
      description: 'Warnings when you approach severe road damage.',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _ready = true;
  }

  /// Called on every GPS update with the currently cached pins.
  void onPosition(Position position, List<HazardReport> reports) {
    if (reports.isEmpty) return;

    HazardReport? nearest;
    double nearestDistance = double.infinity;

    for (final r in reports) {
      if (!r.shouldAlert) continue;

      final d = LocationService.distanceMeters(
        position.latitude,
        position.longitude,
        r.lat,
        r.lon,
      );
      if (d > AppConfig.alertRadiusMeters) continue;
      if (_inCooldown(r.id)) continue;

      if (d < nearestDistance) {
        nearestDistance = d;
        nearest = r;
      }
    }

    // Only ever alert for the single closest qualifying hazard. Firing one
    // notification per pin would produce a burst of four on a bad stretch of
    // road, which trains the user to swipe them away unread.
    if (nearest != null) {
      _fire(nearest, nearestDistance);
    }
  }

  bool _inCooldown(String id) {
    final last = _lastAlerted[id];
    if (last == null) return false;
    return DateTime.now().difference(last) < AppConfig.alertCooldown;
  }

  Future<void> _fire(HazardReport report, double distance) async {
    _lastAlerted[report.id] = DateTime.now();
    onAlert?.call(report, distance);

    if (!_ready) {
      debugPrint('RoadScan: alert suppressed, notifications not initialised');
      return;
    }

    final metres = distance.round();
    final title = report.severity == SeverityClass.critical
        ? 'Severe road damage ahead'
        : 'Road damage ahead';
    final body = '${report.hazard.label} about ${metres}m away '
        '(${report.severity.name}, ${report.confirmationCount} reports)';

    // A thumbnail of the actual damage makes the warning concrete -- the user
    // recognises the spot instead of trusting an abstract severity word.
    // Android can only render a LOCAL bitmap in a notification, so the photo
    // has to be on disk first.
    final thumbnail = await _cachedThumbnail(report);

    final details = AndroidNotificationDetails(
      'roadscan_hazards',
      'Road hazard alerts',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.navigation,
      styleInformation: thumbnail == null
          ? BigTextStyleInformation(body, contentTitle: title)
          : BigPictureStyleInformation(
              FilePathAndroidBitmap(thumbnail),
              largeIcon: FilePathAndroidBitmap(thumbnail),
              contentTitle: title,
              summaryText: body,
            ),
      ticker: title,
    );

    await _plugin.show(
      // Stable per-pin id so a repeat alert replaces rather than stacks.
      _channelHash + report.id.hashCode.abs() % 10000,
      title,
      body,
      NotificationDetails(android: details),
      payload: report.id,
    );
  }

  /// Downloads a pin's latest photo to the cache directory, returning a local
  /// path Android can render, or null if unavailable.
  ///
  /// Returns null rather than throwing on any failure: an alert with no picture
  /// is still a useful alert, and a missing thumbnail must never be the reason
  /// a hazard warning doesn't fire.
  Future<String?> _cachedThumbnail(HazardReport report) async {
    final path = report.latestPhotoPath;
    if (path == null || path.isEmpty) return null;

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/thumb_${report.id}.jpg');

      // Re-use an already-downloaded thumbnail. Alerts fire while moving,
      // often on mobile data, so re-fetching every time would be wasteful.
      if (await file.exists()) return file.path;

      final url = SupabaseService.instance.publicUrl(path);
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;

      await file.writeAsBytes(res.bodyBytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('RoadScan: thumbnail fetch failed: $e');
      return null;
    }
  }

  /// Clears cooldowns. Useful when demoing: walk the same route twice without
  /// waiting out [AppConfig.alertCooldown].
  void resetCooldowns() => _lastAlerted.clear();
}
