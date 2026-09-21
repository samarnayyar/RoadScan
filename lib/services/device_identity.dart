import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// A stable per-install identifier.
///
/// RoadScan deliberately has no accounts -- requiring signup before someone can
/// photograph a pothole kills the report rate, and the report rate is the whole
/// product. So confirmations are attributed to a device, not a user.
///
/// This is a random UUID persisted in SharedPreferences, NOT a hardware ID.
/// Android's hardware identifiers are restricted and privacy-sensitive, and we
/// have no need to recognise the same person across reinstalls. It resets if
/// the user clears app data, which is an acceptable trade for collecting no
/// personal data at all -- worth saying out loud in the report's ethics
/// section.
class DeviceIdentity {
  DeviceIdentity._();
  static final DeviceIdentity instance = DeviceIdentity._();

  static const _key = 'roadscan.device_id';
  String? _cached;

  Future<String> get id async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var value = prefs.getString(_key);
    if (value == null || value.isEmpty) {
      value = const Uuid().v4();
      await prefs.setString(_key, value);
    }
    _cached = value;
    return value;
  }
}
