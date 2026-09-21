import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Thrown when we cannot get a fix and the caller needs to tell the user why.
class LocationUnavailable implements Exception {
  LocationUnavailable(this.message, {this.openSettings = false});
  final String message;

  /// True when the only fix is the user changing a system setting, so the UI
  /// can offer a button instead of a dead-end error.
  final bool openSettings;

  @override
  String toString() => message;
}

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  StreamSubscription<Position>? _sub;
  Position? _last;

  Position? get lastKnown => _last;

  /// Ensures we have permission and the GPS radio is on.
  Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationUnavailable(
        'Location is switched off. Turn on GPS to report or receive alerts.',
        openSettings: true,
      );
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw LocationUnavailable(
        'RoadScan needs location access to pin a hazard to a place.',
      );
    }
    if (perm == LocationPermission.deniedForever) {
      throw LocationUnavailable(
        'Location access is permanently denied. Enable it in app settings.',
        openSettings: true,
      );
    }
  }

  /// A fix good enough to anchor a report.
  ///
  /// Uses high accuracy and a timeout: the dedup radius is 20m, so accepting a
  /// coarse network fix (which can be off by hundreds of metres) would attach
  /// the photo to the wrong stretch of road entirely.
  Future<Position> currentPosition({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await ensurePermission();
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      ).timeout(timeout);
      _last = pos;
      return pos;
    } on TimeoutException {
      // Under tree cover or indoors a fresh fix can time out while a perfectly
      // usable recent one sits in cache.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _last = last;
        return last;
      }
      throw LocationUnavailable(
        'Could not get a GPS fix. Step into the open and try again.',
      );
    }
  }

  /// Fires whenever the user turns location services on or off in system
  /// settings.
  ///
  /// Without this, a map opened while GPS was off stayed permanently blind:
  /// the one-shot fix at startup failed, and nothing ever asked again, so
  /// enabling location did nothing until the screen was rebuilt.
  Stream<ServiceStatus> serviceStatus() => Geolocator.getServiceStatusStream();

  /// Whether a fix is obtainable right now -- services on AND permission
  /// granted. Cheap enough to poll on app resume; does NOT prompt.
  Future<bool> isAvailable() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final perm = await Geolocator.checkPermission();
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  /// Continuous updates for the map dot and proximity alerts.
  ///
  /// The 5m distance filter keeps us from waking the alert check on GPS jitter
  /// while standing still, which is the main avoidable battery cost here.
  Stream<Position> watch({int distanceFilterMeters = 5}) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    ).map((p) {
      _last = p;
      return p;
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) =>
      Geolocator.distanceBetween(lat1, lon1, lat2, lon2);

  static Future<void> openLocationSettings() =>
      Geolocator.openLocationSettings();
}
