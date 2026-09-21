import 'dart:io';

import 'package:flutter/foundation.dart';
// For decodeImageFromList, which returns a Future<ui.Image> (the dart:ui
// function of the same name is callback-based).
import 'package:flutter/painting.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a report's position and time actually came from.
///
/// This is surfaced to the user rather than hidden. "The time on this report is
/// the upload time because your photo had no EXIF date" is information someone
/// filing a road-safety report deserves to see, and it is the difference
/// between a trustworthy time series and a misleading one.
enum MetadataSource {
  /// Read from the photo's own EXIF tags.
  exif,

  /// Taken from the device's live GPS / clock at pick time.
  live,

  /// Placed by the user dragging the pin.
  manual,

  /// Nothing available.
  none,
}

extension MetadataSourceLabel on MetadataSource {
  String get label => switch (this) {
        MetadataSource.exif => 'from photo',
        MetadataSource.live => 'from device',
        MetadataSource.manual => 'set by you',
        MetadataSource.none => 'unavailable',
      };
}

/// Everything known about a picked photo before it becomes a report.
class PhotoMetadata {
  PhotoMetadata({
    required this.file,
    required this.width,
    required this.height,
    this.capturedAt,
    this.capturedAtSource = MetadataSource.none,
    this.latitude,
    this.longitude,
    this.locationSource = MetadataSource.none,
  });

  /// The compressed file that will actually be uploaded.
  File file;

  int width;
  int height;

  DateTime? capturedAt;
  MetadataSource capturedAtSource;

  double? latitude;
  double? longitude;
  MetadataSource locationSource;

  bool get hasLocation => latitude != null && longitude != null;

  /// True when the photo was taken meaningfully before it was uploaded --
  /// i.e. the user is filing a report about an earlier day.
  bool get isBackdated {
    final t = capturedAt;
    if (t == null) return false;
    return DateTime.now().difference(t) > const Duration(hours: 6);
  }

  double get aspectRatio => height == 0 ? 4 / 3 : width / height;
}

/// Picks photos and preserves their metadata.
///
/// The ordering here is the whole point. `image_picker`'s `maxWidth` /
/// `imageQuality` options re-encode the file and DISCARD EXIF, so if we resized
/// at pick time the capture date and GPS would be gone before we ever looked.
/// Instead we pick the original untouched, read EXIF from it, and only then
/// compress a copy for upload.
class PhotoMetadataService {
  PhotoMetadataService._();
  static final PhotoMetadataService instance = PhotoMetadataService._();

  final _picker = ImagePicker();

  /// Longest edge of the uploaded image. The detector runs at 640 px and
  /// Supabase's free tier gives 1 GB of storage, so full 12 MP originals would
  /// be wasteful on both counts.
  static const int _maxEdge = 1600;
  static const int _quality = 85;

  Future<PhotoMetadata?> pick(ImageSource source) async {
    // NOTE: no maxWidth / imageQuality here, deliberately. See class docs.
    final shot = await _picker.pickImage(
      source: source,
      requestFullMetadata: true,
    );
    if (shot == null) return null;

    final original = File(shot.path);
    final meta = PhotoMetadata(file: original, width: 0, height: 0);

    await _readExif(original, meta);
    await _compress(original, meta);

    return meta;
  }

  /// Pulls capture time and GPS out of the original file.
  ///
  /// Every failure here is non-fatal: a photo with no EXIF is still a perfectly
  /// good hazard report. It falls back to live GPS and the upload time, and the
  /// UI says so rather than quietly presenting a guess as fact.
  Future<void> _readExif(File file, PhotoMetadata meta) async {
    try {
      final tags = await readExifFromBytes(await file.readAsBytes());
      if (tags.isEmpty) return;

      final taken = _parseDate(tags);
      if (taken != null) {
        meta.capturedAt = taken;
        meta.capturedAtSource = MetadataSource.exif;
      }

      final lat = _parseCoordinate(
          tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef'], 'S');
      final lon = _parseCoordinate(
          tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef'], 'W');

      // Reject (0,0): a surprising number of cameras write null island rather
      // than omitting the tag, and it would drop a pothole in the Atlantic.
      if (lat != null && lon != null && !(lat == 0 && lon == 0)) {
        meta.latitude = lat;
        meta.longitude = lon;
        meta.locationSource = MetadataSource.exif;
      }
    } catch (e) {
      debugPrint('RoadScan: could not read EXIF from ${file.path}: $e');
    }
  }

  /// EXIF dates look like "2026:09:16 03:45:12" -- colons in the date part, so
  /// DateTime.parse cannot read them directly.
  DateTime? _parseDate(Map<String, IfdTag> tags) {
    for (final key in const [
      'EXIF DateTimeOriginal',
      'EXIF DateTimeDigitized',
      'Image DateTime',
    ]) {
      final raw = tags[key]?.printable.trim();
      if (raw == null || raw.isEmpty) continue;

      final m = RegExp(r'^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
          .firstMatch(raw);
      if (m == null) continue;

      try {
        // Cameras record local wall-clock time with no zone, so build a local
        // DateTime rather than shifting it by the device's UTC offset.
        return DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// EXIF stores coordinates as degrees/minutes/seconds rationals plus a
  /// hemisphere letter, not as a signed decimal.
  double? _parseCoordinate(IfdTag? value, IfdTag? ref, String negativeRef) {
    if (value == null) return null;

    final parts = value.values.toList();
    if (parts.length < 3) return null;

    final deg = _ratio(parts[0]);
    final min = _ratio(parts[1]);
    final sec = _ratio(parts[2]);
    if (deg == null || min == null || sec == null) return null;

    var decimal = deg + min / 60.0 + sec / 3600.0;
    if (decimal.isNaN || decimal.isInfinite) return null;

    final hemisphere = ref?.printable.trim().toUpperCase() ?? '';
    if (hemisphere == negativeRef) decimal = -decimal;

    // Anything outside these bounds is a corrupt tag, not a place.
    if (decimal.abs() > 180) return null;
    return decimal;
  }

  double? _ratio(Object? v) {
    if (v is num) return v.toDouble();
    try {
      // The package models rationals as Ratio(numerator, denominator).
      final dynamic r = v;
      final num numerator = r.numerator as num;
      final num denominator = r.denominator as num;
      if (denominator == 0) return null;
      return numerator / denominator;
    } catch (_) {
      return double.tryParse(v.toString());
    }
  }

  /// Compresses a copy for upload and records its true pixel size.
  ///
  /// The size matters beyond bandwidth: the detector returns normalised boxes,
  /// but the pixel-space fallback path needs the real dimensions to scale them.
  Future<void> _compress(File original, PhotoMetadata meta) async {
    try {
      final dir = await getTemporaryDirectory();
      final target = p.join(
        dir.path,
        'roadscan_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final result = await FlutterImageCompress.compressAndGetFile(
        original.absolute.path,
        target,
        quality: _quality,
        minWidth: _maxEdge,
        minHeight: _maxEdge,
        // keepExif costs a few KB and makes the stored image self-describing,
        // which matters if these photos are ever exported as evidence.
        keepExif: true,
      );

      if (result != null) {
        meta.file = File(result.path);
      }
    } catch (e) {
      // Upload the original rather than losing the report over a failed
      // compression.
      debugPrint('RoadScan: compression failed, using original: $e');
    }

    await _readDimensions(meta);
  }

  Future<void> _readDimensions(PhotoMetadata meta) async {
    try {
      final bytes = await meta.file.readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      meta.width = decoded.width;
      meta.height = decoded.height;
      decoded.dispose();
    } catch (e) {
      debugPrint('RoadScan: could not read image dimensions: $e');
      meta.width = 1600;
      meta.height = 1200;
    }
  }
}
