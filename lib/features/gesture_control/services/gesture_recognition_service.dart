import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/gesture_types.dart';

/// Result from a single gesture detection frame.
class GestureDetectionResult {
  const GestureDetectionResult({
    required this.gesture,
    required this.confidence,
    required this.rawLabel,
  });

  final RecognizedGesture gesture;
  final double confidence;
  final String rawLabel;

  static const none = GestureDetectionResult(
    gesture: RecognizedGesture.none,
    confidence: 0,
    rawLabel: '',
  );
}

/// Bridges Flutter camera frames to the native MediaPipe Gesture Recognizer.
///
/// On Android, frames are processed via a MethodChannel that loads
/// `gesture_recognizer.task` from app assets. Other platforms return [RecognizedGesture.none].
class GestureRecognitionService {
  GestureRecognitionService();

  static const _channel = MethodChannel(
    'com.example.smart_home/gesture_recognizer',
  );

  bool _initialized = false;
  bool _isProcessing = false;

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Loads the MediaPipe model on the native side (Android only).
  Future<bool> initialize() async {
    if (!isSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('initialize');
      _initialized = result ?? false;
      return _initialized;
    } on PlatformException catch (e) {
      debugPrint('GestureRecognitionService init error: ${e.message}');
      return false;
    }
  }

  /// Sends one camera frame for inference. Returns immediately on unsupported platforms.
  Future<GestureDetectionResult> detectFromCameraImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) async {
    if (!isSupported || !_initialized || _isProcessing) {
      return GestureDetectionResult.none;
    }

    _isProcessing = true;
    try {
      // CameraX 0.7.2 streams unrotated YUV planes. Its orientation mapping
      // uses Surface rotation degrees: portraitUp=0, landscapeLeft=90,
      // portraitDown=180, landscapeRight=270. Match CameraX's clockwise
      // relative image rotation (front adds target rotation, back subtracts).
      final deviceRotation = switch (deviceOrientation) {
        DeviceOrientation.portraitUp => 0,
        DeviceOrientation.landscapeLeft => 90,
        DeviceOrientation.portraitDown => 180,
        DeviceOrientation.landscapeRight => 270,
      };
      final rotation =
          (camera.sensorOrientation +
              (camera.lensDirection == CameraLensDirection.front
                  ? deviceRotation
                  : -deviceRotation) +
              360) %
          360;
      final planes = image.planes
          .map(
            (plane) => <String, Object?>{
              'bytes': plane.bytes,
              'bytesPerRow': plane.bytesPerRow,
              'bytesPerPixel': plane.bytesPerPixel,
            },
          )
          .toList(growable: false);

      if (kDebugMode) {
        debugPrint(
          'Gesture Camera: width=${image.width} height=${image.height} '
          'format=${image.format.group.name} lens=${camera.lensDirection.name} '
          'sensorOrientation=${camera.sensorOrientation} '
          'deviceOrientation=${deviceOrientation.name} rotation=$rotation',
        );
        for (var i = 0; i < image.planes.length; i++) {
          final plane = image.planes[i];
          debugPrint(
            'Gesture Plane $i: bytes=${plane.bytes.length} '
            'bytesPerRow=${plane.bytesPerRow} bytesPerPixel=${plane.bytesPerPixel}',
          );
        }
      }

      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('detect', {
            'width': image.width,
            'height': image.height,
            'format': image.format.group.name,
            'planes': planes,
            'sensorOrientation': camera.sensorOrientation,
            'lensDirection': camera.lensDirection.name,
            'deviceOrientation': deviceOrientation.name,
            'deviceRotation': deviceRotation,
            'rotation': rotation,
          });

      if (result == null) return GestureDetectionResult.none;

      final label = result['gesture'] as String? ?? '';
      final confidence = (result['confidence'] as num?)?.toDouble() ?? 0.0;
      final gesture = RecognizedGesture.fromLabel(label);
      if (kDebugMode) {
        debugPrint(
          'Gesture Native: label="$label" confidence=$confidence '
          'parsed=${gesture.name} actionable=${gesture.isActionable}',
        );
      }

      return GestureDetectionResult(
        gesture: gesture,
        confidence: confidence,
        rawLabel: label,
      );
    } on PlatformException catch (e) {
      debugPrint('GestureRecognitionService detect error: ${e.message}');
      return GestureDetectionResult.none;
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> dispose() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    _initialized = false;
  }
}
