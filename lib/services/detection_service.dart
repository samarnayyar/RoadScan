import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../config/app_config.dart';
import '../models/detection.dart';

/// Thrown when the model cannot be loaded at all.
class ModelLoadFailure implements Exception {
  ModelLoadFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Wraps the Ultralytics plugin so the rest of the app never sees its raw
/// result maps.
///
/// The core detection step runs entirely on-device: no network call, which was
/// a hard requirement. The model is a YOLO nano export in LiteRT format (see
/// ml/train_export.py). Note that Ultralytics REMOVED the standalone `tflite`
/// export format in 8.4.83 -- `format="litert"` is the only route now, though
/// it still emits a .tflite file.
class DetectionService {
  DetectionService._();
  static final DetectionService instance = DetectionService._();

  YOLO? _yolo;
  Future<void>? _loading;

  /// True when the fine-tuned model was missing and we fell back to a stock
  /// COCO model. The UI surfaces this so nobody demos a "working detector"
  /// that is actually looking for buses and giraffes.
  bool usingFallbackModel = false;

  bool get isReady => _yolo != null;

  /// Idempotent and safe to call concurrently -- the capture screen warms the
  /// model on open while `detect` may also trigger a load.
  Future<void> load() {
    if (_yolo != null) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final haveCustom = await _assetExists(AppConfig.modelAsset);
    usingFallbackModel = !haveCustom;

    final path = haveCustom ? AppConfig.modelAsset : AppConfig.fallbackModelId;
    final yolo = YOLO(modelPath: path, task: YOLOTask.detect);

    // loadModel() reports failure by RETURN VALUE, not by throwing. Ignoring
    // it would leave `_yolo` set to an unusable instance and turn every later
    // predict() into a confusing platform exception.
    final ok = await yolo.loadModel();
    if (!ok) {
      throw ModelLoadFailure(
        'Could not load "$path". If this is the bundled asset, re-run '
        'ml/train_export.py export.',
      );
    }
    _yolo = yolo;

    if (usingFallbackModel) {
      debugPrint(
        'RoadScan: ${AppConfig.modelAsset} not bundled. Falling back to '
        '"${AppConfig.fallbackModelId}", which cannot detect potholes. '
        'Run ml/train_export.py and drop the export into assets/models/.',
      );
    }
  }

  /// Runs detection on encoded image bytes (JPEG/PNG straight off the camera).
  ///
  /// [imageWidth]/[imageHeight] are only used as a fallback if the plugin
  /// returns a degenerate normalised box; pass them when known.
  Future<List<Detection>> detect(
    Uint8List imageBytes, {
    int? imageWidth,
    int? imageHeight,
  }) async {
    await load();
    final yolo = _yolo;
    if (yolo == null) return const [];

    // Push the threshold down into the plugin rather than filtering after the
    // fact: it lets native-side NMS discard weak boxes before they are ever
    // serialised across the platform channel.
    final raw = await yolo.predict(
      imageBytes,
      confidenceThreshold: AppConfig.minConfidence,
    );

    final out = <Detection>[];
    for (final result in _resultsFrom(raw)) {
      final hazard = HazardClass.fromLabel(result.className);
      // Silently drop classes we do not model. The stock COCO fallback emits
      // 'person', 'car' and so on, and none of them are road damage.
      if (hazard == null) continue;
      if (result.confidence < AppConfig.minConfidence) continue;

      final rect = _normalisedRect(result, imageWidth, imageHeight);
      if (rect == null) continue;

      out.add(Detection(
        hazard: hazard,
        confidence: result.confidence,
        left: rect.left.clamp(0.0, 1.0),
        top: rect.top.clamp(0.0, 1.0),
        right: rect.right.clamp(0.0, 1.0),
        bottom: rect.bottom.clamp(0.0, 1.0),
      ));
    }
    return out;
  }

  Future<void> dispose() async {
    _yolo = null;
  }

  /// `predict()` returns a map, documented as carrying a 'detections' list of
  /// YOLOResult-compatible maps, with 'boxes' as an older/parallel key.
  List<YOLOResult> _resultsFrom(Map<String, dynamic> raw) {
    for (final key in const ['detections', 'boxes']) {
      final value = raw[key];
      if (value is! List) continue;

      final parsed = <YOLOResult>[];
      for (final item in value) {
        if (item is YOLOResult) {
          parsed.add(item);
        } else if (item is Map) {
          try {
            parsed.add(YOLOResult.fromMap(item));
          } catch (e) {
            debugPrint('RoadScan: skipped an unparseable detection: $e');
          }
        }
      }
      if (parsed.isNotEmpty) return parsed;
    }
    return const [];
  }

  /// Prefers the plugin's own normalised box.
  ///
  /// `YOLOResult.fromMap` defaults `normalizedBox` to `Rect.zero` when the
  /// platform side omits it, and a zero-area box would score as severity 0 --
  /// a hazard silently rated harmless. So fall back to the pixel box divided
  /// by the real image size, and give up rather than guess if neither is
  /// usable.
  Rect? _normalisedRect(YOLOResult result, int? imageWidth, int? imageHeight) {
    final norm = result.normalizedBox;
    if (norm.width > 0 && norm.height > 0) return norm;

    final px = result.boundingBox;
    if (px.width > 0 &&
        px.height > 0 &&
        imageWidth != null &&
        imageHeight != null &&
        imageWidth > 0 &&
        imageHeight > 0) {
      return Rect.fromLTRB(
        px.left / imageWidth,
        px.top / imageHeight,
        px.right / imageWidth,
        px.bottom / imageHeight,
      );
    }

    debugPrint('RoadScan: dropped "${result.className}" -- no usable box');
    return null;
  }

  Future<bool> _assetExists(String key) async {
    try {
      await rootBundle.load(key);
      return true;
    } catch (_) {
      return false;
    }
  }
}
