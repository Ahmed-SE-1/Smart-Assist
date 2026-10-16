import '../models/gesture_types.dart';

/// Confirms a gesture across [confirmationFrames] predictions and requires release
/// before another activation. Low-confidence flicker cannot release the latch.
class GestureActivationGate {
  GestureActivationGate({required this.target, this.confirmationFrames = 3});

  final RecognizedGesture target;
  final int confirmationFrames;
  int _stableFrames = 0;
  int _releaseFrames = 0;
  bool _latched = false;

  bool accept(
    RecognizedGesture gesture, {
    required double confidence,
    required double threshold,
    required bool canTrigger,
  }) {
    final confident = confidence.isFinite && confidence >= threshold;
    if (gesture != target || !confident) {
      _stableFrames = 0;
      if (gesture == RecognizedGesture.none ||
          (gesture != target && confident)) {
        if (++_releaseFrames >= 3) _latched = false;
      } else {
        _releaseFrames = 0;
      }
      return false;
    }

    _releaseFrames = 0;
    if (_latched || !canTrigger) {
      _stableFrames = 0;
      return false;
    }
    if (++_stableFrames < confirmationFrames) return false;
    _latched = true;
    _stableFrames = 0;
    return true;
  }
}
