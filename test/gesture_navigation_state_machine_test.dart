import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/features/gesture_control/models/gesture_types.dart';
import 'package:smart_home/features/gesture_control/state/gesture_navigation_state_machine.dart';

void main() {
  const rooms = [
    GestureRoomItem(id: 'r1', name: 'Ahmed Room'),
    GestureRoomItem(id: 'r2', name: 'Bedroom'),
  ];

  const devices = [
    GestureDeviceItem(
      id: 'd1',
      name: 'Light 1',
      roomId: 'r1',
      isControllable: true,
    ),
    GestureDeviceItem(
      id: 'd2',
      name: 'Bulb',
      roomId: 'r1',
      isControllable: true,
    ),
    GestureDeviceItem(
      id: 'd3',
      name: 'Sensor',
      roomId: 'r2',
      isControllable: false,
    ),
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

    for (final navState in GestureNavState.values) {
      test('ILoveYou requests all OFF without navigation from $navState', () {
        if (navState != GestureNavState.roomsList) {
          machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        }
        if (navState == GestureNavState.deviceAction) {
          machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        }
        final before = machine.snapshot();
        final result = machine.handleGesture(
          RecognizedGesture.fromLabel('ILoveYou'),
          confidence: 0.88,
        );
        expect(result.action, GestureNavActionType.allDevicesOff);
        expect(result.snapshot.navState, before.navState);
        expect(result.snapshot.selectedRoomId, before.selectedRoomId);
        expect(result.snapshot.selectedDeviceId, before.selectedDeviceId);
        expect(result.snapshot.selectedRoomIndex, before.selectedRoomIndex);
        expect(result.snapshot.selectedDeviceIndex, before.selectedDeviceIndex);
        expect(
          result.ttsMessage,
          isNull,
        ); // Success is announced after commands.
      });
    }

    test('Fist backs out one level at a time', () {
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
      final devices = machine.handleGesture(
        RecognizedGesture.closedFist,
        confidence: 0.9,
      );
      expect(devices.action, GestureNavActionType.goBack);
      expect(machine.navState, GestureNavState.devicesList);
      final rooms = machine.handleGesture(
        RecognizedGesture.closedFist,
        confidence: 0.9,
      );
      expect(rooms.action, GestureNavActionType.goBack);
      expect(machine.navState, GestureNavState.roomsList);
    });

    test(
      'Thumb Down never navigates; Next, Select and Victory remain unchanged',
      () {
        final roomsResult = machine.handleGesture(
          RecognizedGesture.thumbDown,
          confidence: 0.9,
        );
        expect(roomsResult.hasEffect, isFalse);
        expect(machine.selectedRoomIndex, 0);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        machine.handleGesture(RecognizedGesture.pointingUp, confidence: 0.9);
        expect(machine.selectedDeviceIndex, 1);
        final devicesResult = machine.handleGesture(
          RecognizedGesture.thumbDown,
          confidence: 0.9,
        );
        expect(devicesResult.hasEffect, isFalse);
        expect(machine.selectedDeviceIndex, 1);
        machine.handleGesture(RecognizedGesture.pointingUp, confidence: 0.9);
        expect(machine.selectedDeviceIndex, 0);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        final off = machine.handleGesture(
          RecognizedGesture.victory,
          confidence: 0.9,
        );
        expect(off.action, GestureNavActionType.turnOffDevice);
        expect(off.deviceId, 'd1');
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.9)
              .hasEffect,
          isFalse,
        );
      },
    );

    test(
      'Selected supported device produces semantic adjustment; removal clears selection',
      () {
        const fan = GestureDeviceItem(
          id: 'fan',
          name: 'Fan',
          roomId: 'r1',
          isControllable: true,
          supportsAdjustment: true,
        );
        machine.updateData(rooms: rooms, devices: [fan]);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.9)
              .hasEffect,
          isFalse,
        );
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        expect(machine.selectedDeviceSupportsAdjustment, isTrue);
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.74)
              .hasEffect,
          isFalse,
        );
        final adjustment = machine.handleGesture(
          RecognizedGesture.fromLabel('Thumb_Down'),
          confidence: 0.9,
        );
        expect(adjustment.action, GestureNavActionType.adjustDevice);
        expect(adjustment.deviceId, 'fan');
        expect(machine.navState, GestureNavState.deviceAction);
        expect(adjustment.ttsMessage, isNull);
        machine.updateData(rooms: rooms, devices: []);
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.9)
              .hasEffect,
          isFalse,
        );
      },
    );

    test(
      'Adjustment follows selected device ID after Back and a new selection',
      () {
        const adjustable = [
          GestureDeviceItem(
            id: 'fan',
            name: 'Fan',
            roomId: 'r1',
            isControllable: true,
            supportsAdjustment: true,
          ),
          GestureDeviceItem(
            id: 'ac',
            name: 'AC',
            roomId: 'r1',
            isControllable: true,
            supportsAdjustment: true,
          ),
        ];
        machine.updateData(rooms: rooms, devices: adjustable);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.9)
              .deviceId,
          'fan',
        );
        machine.handleGesture(RecognizedGesture.closedFist, confidence: 0.9);
        machine.handleGesture(RecognizedGesture.pointingUp, confidence: 0.9);
        machine.handleGesture(RecognizedGesture.openPalm, confidence: 0.9);
        expect(
          machine
              .handleGesture(RecognizedGesture.thumbDown, confidence: 0.9)
              .deviceId,
          'ac',
        );
      },
    );

    test(
      'Thumb Down guide matches availability and never advertises Previous',
      () {
        for (final state in GestureNavState.values) {
          final hint = gestureActionHintsFor(
            state,
          ).singleWhere((h) => h.gesture == RecognizedGesture.thumbDown);
          expect(hint.action, isNot(contains('Previous')));
          expect(hint.isAvailable, isFalse);
        }
        expect(
          gestureActionHintsFor(
                GestureNavState.deviceAction,
                supportsAdjustment: true,
              )
              .singleWhere((h) => h.gesture == RecognizedGesture.thumbDown)
              .isAvailable,
          isTrue,
        );
      },
    );

    test('Global OFF rejects low and invalid confidence', () {
      for (final confidence in [0.74, double.nan, double.infinity]) {
        expect(
          machine
              .handleGesture(RecognizedGesture.iLoveYou, confidence: confidence)
              .hasEffect,
          isFalse,
        );
      }
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
