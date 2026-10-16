import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/features/gesture_control/models/gesture_types.dart';
import 'package:smart_home/features/gesture_control/state/gesture_activation_gate.dart';

void main() {
  test(
    'Thumb Down increments once per hold and requires release after cooldown',
    () {
      final gate = GestureActivationGate(
        target: RecognizedGesture.thumbDown,
        confirmationFrames: 1,
      );
      bool frame(
        RecognizedGesture gesture, {
        double confidence = 0.9,
        bool ready = true,
      }) => gate.accept(
        gesture,
        confidence: confidence,
        threshold: 0.75,
        canTrigger: ready,
      );
      expect(frame(RecognizedGesture.thumbDown, confidence: 0.74), isFalse);
      expect(frame(RecognizedGesture.thumbDown, ready: false), isFalse);
      expect(frame(RecognizedGesture.thumbDown), isTrue);
      for (var i = 0; i < 100; i++) {
        expect(frame(RecognizedGesture.thumbDown), isFalse);
      }
      // A selected-device change alone cannot rearm a held sign.
      expect(frame(RecognizedGesture.thumbDown), isFalse);
      expect(frame(RecognizedGesture.none), isFalse);
      expect(frame(RecognizedGesture.thumbDown), isFalse);
      for (var i = 0; i < 3; i++) {
        expect(frame(RecognizedGesture.openPalm, ready: false), isFalse);
      }
      expect(frame(RecognizedGesture.thumbDown), isTrue);
    },
  );
  test(
    'Global OFF requires stable frames, fires once while held, and rearms on release',
    () {
      final gate = GestureActivationGate(target: RecognizedGesture.iLoveYou);
      bool frame(
        RecognizedGesture gesture, {
        double confidence = 0.9,
        bool ready = true,
      }) => gate.accept(
        gesture,
        confidence: confidence,
        threshold: 0.75,
        canTrigger: ready,
      );

      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      expect(frame(RecognizedGesture.iLoveYou, confidence: 0.7), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isTrue);
      for (var i = 0; i < 100; i++) {
        expect(frame(RecognizedGesture.iLoveYou), isFalse);
      }
      for (var i = 0; i < 5; i++) {
        expect(frame(RecognizedGesture.iLoveYou, confidence: 0.2), isFalse);
      }
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      // A single missing-hand frame cannot rearm the held gesture.
      expect(frame(RecognizedGesture.none), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      for (var i = 0; i < 3; i++) {
        expect(frame(RecognizedGesture.none), isFalse);
      }
      for (var i = 0; i < 5; i++) {
        expect(frame(RecognizedGesture.iLoveYou, ready: false), isFalse);
      }
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isFalse);
      expect(frame(RecognizedGesture.iLoveYou), isTrue);
    },
  );
}
