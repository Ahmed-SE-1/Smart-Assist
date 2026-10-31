import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home/core/mqtt_config.dart';
import 'package:smart_home/models/device.dart';
import 'package:smart_home/models/pir_motion_event.dart';
import 'package:smart_home/models/room.dart';
import 'package:smart_home/providers/service_providers.dart';
import 'package:smart_home/providers/smart_home_provider.dart';
import 'package:smart_home/screens/main_layout.dart';
import 'package:smart_home/services/iot_simulation_service.dart';
import 'package:smart_home/services/mqtt_service.dart';

class _Rooms extends RoomsNotifier {
  _Rooms(this.seed);
  final List<Room> seed;

  @override
  List<Room> build() => seed;
}

class _Devices extends DevicesNotifier {
  _Devices(this.seed);
  final List<Device> seed;

  @override
  List<Device> build() => seed;
}

class _Mqtt extends MqttService {
  final published = <String>[];

  @override
  Future<CommandResult> publishDeviceCommand({
    required String houseId,
    required String mqttDeviceId,
    required int channel,
    required String state,
  }) async {
    published.add('$mqttDeviceId:$channel:$state');
    return CommandResult(
      success: true,
      deviceId: '',
      roomId: '',
      action: state,
      method: 'mqtt',
      timestamp: DateTime.now(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const room1Light = Device(
    id: 'room1-light',
    name: 'Room 1 Light',
    type: DeviceType.light,
    roomId: 'room-1',
    channel: RelayChannel.light,
  );
  const room2Light = Device(
    id: 'room2-light',
    name: 'Room 2 Light',
    type: DeviceType.light,
    roomId: 'room-2',
    channel: RelayChannel.light,
  );
  const room2Fan = Device(
    id: 'room2-fan',
    name: 'Room 2 Fan',
    type: DeviceType.fan,
    roomId: 'room-2',
    channel: RelayChannel.fan,
  );

  Room mappedRoom(String id, String name, String nodeId) => Room(
    id: id,
    name: name,
    iconAsset: 'bed',
    esp32NodeId: 'NODE_00$id',
    mqttNodeId: nodeId,
    creatorId: 'owner',
    creatorName: 'Owner',
  );

  late ProviderContainer container;

  void setup({List<Device>? devices}) {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [
        roomsProvider.overrideWith(
          () => _Rooms([
            mappedRoom('room-1', 'Room 1', Room.room1NodeId),
            mappedRoom('room-2', 'Room 2', Room.room2NodeId),
          ]),
        ),
        devicesProvider.overrideWith(
          () => _Devices(devices ?? [room1Light, room2Light, room2Fan]),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  PirMotionEvent parse({
    String nodeId = Room.room2NodeId,
    String houseId = 'house-1',
    String expectedHouseId = 'house-1',
    String payload = '',
    bool on = true,
  }) {
    final body =
        payload.isNotEmpty
            ? payload
            : jsonEncode({
              'event': on ? 'motion' : 'motion_timeout',
              'sensor': 'PIR',
              'device': 'light',
              'state': on ? 'ON' : 'OFF',
              'reason': on ? 'motion' : 'motion_timeout',
            });
    final event = PirMotionEvent.tryParse(
      topic: 'smartassist/$houseId/$nodeId/events',
      payload: body,
      expectedHouseId: expectedHouseId,
    );
    expect(event, isNotNull);
    return event!;
  }

  Device byId(String id) =>
      container.read(devicesProvider).firstWhere((device) => device.id == id);

  test('Valid Room 2 PIR ON event turns on only that light', () {
    setup();
    final applied = container
        .read(devicesProvider.notifier)
        .applyPirMotionEvent(parse());
    expect(applied, isTrue);
    expect(byId('room2-light').isOn, isTrue);
    expect(byId('room1-light').isOn, isFalse);
    expect(byId('room2-fan').isOn, isFalse);
    final notice = container.read(pirNoticeProvider).single;
    expect(notice.title, 'Automatic Light Activation');
    expect(
      notice.message,
      'Room 2 Light turned ON due to PIR motion detection.',
    );
  });

  test('Valid PIR OFF event turns Room 2 light off', () {
    setup(devices: [room1Light, room2Light.copyWith(isOn: true), room2Fan]);
    final applied = container
        .read(devicesProvider.notifier)
        .applyPirMotionEvent(parse(on: false));
    expect(applied, isTrue);
    expect(byId('room2-light').isOn, isFalse);
    expect(byId('room1-light').isOn, isFalse);
    expect(
      container.read(pirNoticeProvider).single.message,
      'Room 2 Light turned OFF after motion timeout.',
    );
  });

  test('Unknown node and unknown device events are ignored', () {
    expect(
      PirMotionEvent.tryParse(
        topic: 'smartassist/house-1/NODE_009/events',
        payload: jsonEncode({
          'event': 'motion',
          'sensor': 'PIR',
          'device': 'light',
          'state': 'ON',
        }),
        expectedHouseId: 'house-1',
      ),
      isNull,
    );
    expect(
      PirMotionEvent.tryParse(
        topic: 'smartassist/house-1/${Room.room2NodeId}/events',
        payload: jsonEncode({
          'event': 'motion',
          'sensor': 'PIR',
          'device': 'fan',
          'state': 'ON',
        }),
        expectedHouseId: 'house-1',
      ),
      isNull,
    );

    container = ProviderContainer(
      overrides: [
        roomsProvider.overrideWith(
          () => _Rooms([mappedRoom('room-2', 'Room 2', Room.room2NodeId)]),
        ),
        devicesProvider.overrideWith(
          () => _Devices([
            const Device(
              id: 'fan-only',
              name: 'Fan',
              type: DeviceType.fan,
              roomId: 'room-2',
              channel: RelayChannel.fan,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final applied = container
        .read(devicesProvider.notifier)
        .applyPirMotionEvent(parse());
    expect(applied, isFalse);
    expect(container.read(devicesProvider).single.isOn, isFalse);
    expect(container.read(pirNoticeProvider), isEmpty);
  });

  test('Malformed JSON is ignored', () {
    expect(
      PirMotionEvent.tryParse(
        topic: 'smartassist/house-1/${Room.room2NodeId}/events',
        payload: '{',
        expectedHouseId: 'house-1',
      ),
      isNull,
    );
    expect(
      PirMotionEvent.tryParse(
        topic: 'smartassist/house-1/${Room.room2NodeId}/events',
        payload: 'null',
        expectedHouseId: 'house-1',
      ),
      isNull,
    );
  });

  test('Duplicate PIR events do not create duplicate notifications', () {
    setup();
    final notifier = container.read(devicesProvider.notifier);
    expect(notifier.applyPirMotionEvent(parse()), isTrue);
    expect(notifier.applyPirMotionEvent(parse()), isFalse);
    expect(container.read(pirNoticeProvider), hasLength(1));
    expect(byId('room2-light').isOn, isTrue);
    expect(byId('room1-light').isOn, isFalse);
  });

  test(
    'Manual light control still publishes and does not raise a PIR notice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final mqtt = _Mqtt();
      container = ProviderContainer(
        overrides: [
          roomsProvider.overrideWith(
            () => _Rooms([mappedRoom('room-2', 'Room 2', Room.room2NodeId)]),
          ),
          devicesProvider.overrideWith(() => _Devices([room2Light])),
          mqttServiceProvider.overrideWithValue(mqtt),
          mqttConfigProvider.overrideWithValue(
            const MqttConfig(
              enabled: true,
              host: 'broker.example',
              port: 8883,
              username: 'mqtt-user',
              password: 'mqtt-pass',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final success = await container
          .read(devicesProvider.notifier)
          .toggleDevice(room2Light);
      expect(success, isTrue);
      expect(byId('room2-light').isOn, isTrue);
      expect(mqtt.published, ['${Room.room2NodeId}:2:ON']);
      expect(container.read(pirNoticeProvider), isEmpty);
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets('A PIR notice shows the automation SnackBar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) => MainLayout(child: child),
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(MainLayout));
    ProviderScope.containerOf(context)
        .read(pirNoticeProvider.notifier)
        .show(
          PirAutomationNotice.forRoom(
            roomId: 'room-2',
            roomName: 'Room 2',
            deviceId: 'room2-light',
            lightOn: true,
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Automatic Light Activation'), findsOneWidget);
    expect(
      find.text('Room 2 Light turned ON due to PIR motion detection.'),
      findsOneWidget,
    );
  });
}
