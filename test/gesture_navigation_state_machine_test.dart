import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/features/gesture_control/models/gesture_types.dart';
import 'package:smart_home/features/gesture_control/state/gesture_navigation_state_machine.dart';

void main() {
  const rooms = [
    GestureRoomItem(id: 'r1', name: 'Ahmed Room'),
    GestureRoomItem(id: 'r2', name: 'Bedroom'),
  ];

  const devices = [
    GestureDeviceItem(id: 'd1', name: 'Light 1', roomId: 'r1', isControllable: true),
    GestureDeviceItem(id: 'd2', name: 'Bulb', roomId: 'r1', isControllable: true),
    GestureDeviceItem(id: 'd3', name: 'Sensor', roomId: 'r2', isControllable: false),
  ];

  group('GestureNavigationStateMachine', () {
    late GestureNavigationStateMachine machine;

    setUp(() {
      machine = GestureNavigationStateMachine(
        rooms: rooms,
        devices: devices,
        confidenceThreshold: 0.75,
      );
    });

    test('Pointing_Up moves to next room', () {
      final result = machine.handleGesture(
        RecognizedGesture.pointingUp,
        confidence: 0.9,
      );
      expect(result.action, GestureNavActionType.moveNext);
      expect(result.snapshot.selectedRoomIndex, 1);
      expect(result.ttsMessage, 'Bedroom');
    });

    test('Open_Palm selects room and enters devices_list', () {
      final result = machine.handleGesture(
        RecognizedGesture.openPalm,
        confidence: 0.85,
      );
      expect(result.action, GestureNavActionType.confirmSelection);
      expect(result.snapshot.navState, GestureNavState.devicesList);
      expect(result.snapshot.selectedRoomId, 'r1');
    });

    test('Closed_Fist from rooms_list exits mode', () {
      final result = machine.handleGesture(
        RecognizedGesture.closedFist,
        confidence: 0.9,
      );
      expect(result.action, GestureNavActionType.exitMode);
    });

    test('ILoveYou jumps back to rooms from device_action', () {
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      expect(machine.navState, GestureNavState.deviceAction);

      final result = machine.handleGesture(
        RecognizedGesture.iLoveYou,
        confidence: 0.88,
      );
      expect(result.action, GestureNavActionType.jumpToRooms);
      expect(result.snapshot.navState, GestureNavState.roomsList);
    });

    test('Thumb_Up turns on device only in device_action state', () {
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);

      final result = machine.handleGesture(
        RecognizedGesture.thumbUp,
        confidence: 0.92,
      );
      expect(result.action, GestureNavActionType.turnOnDevice);
      expect(result.deviceId, 'd1');
    });

    test('Low confidence gestures are ignored', () {
      final result = machine.handleGesture(
        RecognizedGesture.thumbUp,
        confidence: 0.5,
      );
      expect(result.action, GestureNavActionType.none);
    });

    test('Unknown gesture does not reset navigation', () {
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      final before = machine.navState;

      final result = machine.handleGesture(
        RecognizedGesture.unknown,
        confidence: 0.99,
      );
      expect(result.action, GestureNavActionType.none);
      expect(machine.navState, before);
    });
  });
}
