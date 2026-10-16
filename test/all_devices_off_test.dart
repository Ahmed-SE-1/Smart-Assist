import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home/models/device.dart';
import 'package:smart_home/providers/service_providers.dart';
import 'package:smart_home/providers/smart_home_provider.dart';
import 'package:smart_home/services/iot_simulation_service.dart';
import 'package:smart_home/services/mqtt_service.dart';

class _SeededDevices extends DevicesNotifier {
  _SeededDevices(this.devices);
  final List<Device> devices;

  @override
  List<Device> build() => devices;
}

class _Mqtt extends MqttService {
  final commands = <String>[];
  final failIds = <String>{};
  final throwIds = <String>{};
  int active = 0;
  int maxActive = 0;

  @override
  Future<CommandResult> publishCommand({
    required Device device,
    required String action,
    required String method,
  }) async {
    active++;
    if (active > maxActive) maxActive = active;
    commands.add('${device.id}:$action:$method');
    try {
      await Future<void>.delayed(Duration.zero);
      if (throwIds.contains(device.id)) throw Exception('Backend unavailable');
      return CommandResult(
        success: !failIds.contains(device.id),
        deviceId: device.id,
        roomId: device.roomId,
        action: action,
        method: method,
        timestamp: DateTime.now(),
      );
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const devices = [
    Device(
      id: 'light',
      name: 'Light',
      type: DeviceType.light,
      roomId: 'r1',
      isOn: true,
    ),
    Device(
      id: 'fan',
      name: 'Fan',
      type: DeviceType.fan,
      roomId: 'r2',
      isOn: true,
    ),
    Device(id: 'ac', name: 'AC', type: DeviceType.ac, roomId: 'r3', isOn: true),
    Device(id: 'off', name: 'Off light', type: DeviceType.light, roomId: 'r2'),
    Device(
      id: 'sensor',
      name: 'Sensor',
      type: DeviceType.sensor,
      roomId: 'r1',
      isOn: true,
    ),
  ];

  late ProviderContainer container;
  late _Mqtt mqtt;
  void setup(List<Device> seed) {
    SharedPreferences.setMockInitialValues({});
    mqtt = _Mqtt();
    container = ProviderContainer(
      overrides: [
        devicesProvider.overrideWith(() => _SeededDevices(seed)),
        mqttServiceProvider.overrideWithValue(mqtt),
      ],
    );
    addTearDown(container.dispose);
  }

  test(
    'All rooms use sequential existing OFF commands; sensors and OFF devices are skipped',
    () async {
      setup(devices);
      final result = await container
          .read(devicesProvider.notifier)
          .turnOffAll(method: 'gesture');
      expect(mqtt.commands, [
        'light:OFF:gesture',
        'fan:OFF:gesture',
        'ac:OFF:gesture',
      ]);
      expect(mqtt.maxActive, 1);
      expect(result.turnedOffCount, 3);
      expect(result.alreadyOffCount, 1);
      expect(result.failedCount, 0);
      expect(result.message, 'All devices have been turned OFF.');
      expect(
        container
            .read(devicesProvider)
            .where((d) => d.type != DeviceType.sensor)
            .every((d) => !d.isOn),
        isTrue,
      );
      expect(container.read(devicesProvider).last.isOn, isTrue);
      expect(container.read(activityLogProvider).length, 3);
      // Holding/repeating an action after success sends no additional commands.
      final again = await container.read(devicesProvider.notifier).turnOffAll();
      expect(mqtt.commands.length, 3);
      expect(again.message, 'All devices are already OFF.');
      await Future<void>.delayed(
        Duration.zero,
      ); // Let existing persistence finish.
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('shared_house_devices_db_default'),
        contains('"isOn":false'),
      );
    },
  );

  test(
    'Failures and exceptions preserve ON state and do not abort remaining devices',
    () async {
      setup(devices);
      mqtt.failIds.add('light');
      mqtt.throwIds.add('fan');
      final result = await container
          .read(devicesProvider.notifier)
          .turnOffAll(method: 'gesture');
      expect(result.failedCount, 2);
      expect(result.turnedOffCount, 1);
      expect(result.message, contains('2 devices could not be turned OFF'));
      final state = container.read(devicesProvider);
      expect(state[0].isOn, isTrue);
      expect(state[1].isOn, isTrue);
      expect(state[2].isOn, isFalse);
      expect(container.read(activityLogProvider).length, 1);
      expect(mqtt.commands.length, 3);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('Empty house and sensor-only house send no commands', () async {
    setup([]);
    expect(
      (await container.read(devicesProvider.notifier).turnOffAll()).message,
      'No controllable devices found.',
    );
    expect(mqtt.commands, isEmpty);
  });

  test('Sensor-only house has no controllable devices', () async {
    setup([devices.last]);
    final result = await container.read(devicesProvider.notifier).turnOffAll();
    expect(result.controllableCount, 0);
    expect(mqtt.commands, isEmpty);
  });

  test(
    'Complete backend failure never reports success or updates devices',
    () async {
      setup(devices);
      mqtt.failIds.addAll(['light', 'fan', 'ac']);
      final result =
          await container.read(devicesProvider.notifier).turnOffAll();
      expect(result.failedCount, 3);
      expect(result.turnedOffCount, 0);
      expect(container.read(devicesProvider), devices);
      expect(container.read(activityLogProvider), isEmpty);
    },
  );
}
