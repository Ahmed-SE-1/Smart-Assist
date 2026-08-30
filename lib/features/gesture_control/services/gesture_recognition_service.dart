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

  static const _channel = MethodChannel('com.example.smart_home/gesture_recognizer');

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
  Future<GestureDetectionResult> detectFromCameraImage(CameraImage image) async {
    if (!isSupported || !_initialized || _isProcessing) {
      return GestureDetectionResult.none;
    }

    _isProcessing = true;
    try {
      final planes = image.planes
          .map((plane) => plane.bytes)
          .toList(growable: false);

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'detect',
        {
          'width': image.width,
          'height': image.height,
          'format': image.format.group.name,
          'planes': planes,
          'bytesPerRow': image.planes.first.bytesPerRow,
        },
      );

      if (result == null) return GestureDetectionResult.none;

      final label = result['gesture'] as String? ?? '';
      final confidence = (result['confidence'] as num?)?.toDouble() ?? 0.0;

      return GestureDetectionResult(
        gesture: RecognizedGesture.fromLabel(label),
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
