import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home/models/device.dart';
import 'package:smart_home/providers/service_providers.dart';
import 'package:smart_home/providers/smart_home_provider.dart';
import 'package:smart_home/services/iot_simulation_service.dart';
import 'package:smart_home/services/mqtt_service.dart';

class _Devices extends DevicesNotifier {
  _Devices(this.seed);
  final List<Device> seed;
  @override
  List<Device> build() => seed;

  void receiveUpdate(Device device) {
    state = state.map((d) => d.id == device.id ? device : d).toList();
  }
}

class _Mqtt extends MqttService {
  final commands = <String>[];
  bool success = true;
  bool throws = false;
  @override
  Future<CommandResult> publishCommand({
    required Device device,
    required String action,
    required String method,
  }) async {
    commands.add('${device.id}:$action:$method');
    if (throws) throw Exception('Unavailable or unauthorized');
    return CommandResult(
      success: success,
      deviceId: device.id,
      roomId: device.roomId,
      action: action,
      method: method,
      timestamp: DateTime.now(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fan = Device(
    id: 'fan',
    name: 'Fan',
    type: DeviceType.fan,
    roomId: 'r1',
    fanSpeed: 1,
    isOn: true,
  );
  const ac = Device(
    id: 'ac',
    name: 'AC',
    type: DeviceType.ac,
    roomId: 'r2',
    acTemperature: 16,
    isOn: true,
  );
  late ProviderContainer container;
  late _Devices notifier;
  late _Mqtt mqtt;

  void setup(List<Device> seed) {
    SharedPreferences.setMockInitialValues({});
    mqtt = _Mqtt();
    notifier = _Devices(seed);
    container = ProviderContainer(
      overrides: [
        devicesProvider.overrideWith(() => notifier),
        mqttServiceProvider.overrideWithValue(mqtt),
      ],
    );
    container.read(devicesProvider);
    addTearDown(container.dispose);
  }

  tearDown(() async {
    await Future<void>.delayed(Duration.zero); // Finish existing persistence.
  });

  test(
    'Fan steps through 1–5 then wraps to 1 through the manual setter',
    () async {
      setup([fan, ac]);
      for (final speed in [2, 3, 4, 5, 1]) {
        expect(
          await notifier.cycleDeviceAdjustment('fan', method: 'gesture'),
          'Fan speed set to $speed.',
        );
        expect(notifier.getById('fan')!.fanSpeed, speed);
        expect(notifier.getById('fan')!.isOn, isTrue);
        expect(mqtt.commands.last, 'fan:SPEED_$speed:gesture');
      }
      expect(notifier.getById('ac')!.acTemperature, 16);
      expect(container.read(activityLogProvider).length, 5);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'shared_house_devices_db_default',
        ),
        contains('"fanSpeed":1'),
      );
    },
  );

  test('AC steps from 16 to 30 then wraps to 16', () async {
    setup([ac]);
    for (final temperature in [...List.generate(14, (i) => i + 17), 16]) {
      expect(
        await notifier.cycleDeviceAdjustment('ac', method: 'gesture'),
        'AC temperature set to $temperature degrees.',
      );
      expect(notifier.getById('ac')!.acTemperature, temperature);
      expect(mqtt.commands.last, 'ac:TEMP_$temperature:gesture');
    }
  });

  test(
    'OFF fan follows manual slider power behavior; OFF AC requires ON',
    () async {
      setup([fan.copyWith(isOn: false, fanSpeed: 0), ac.copyWith(isOn: false)]);
      await notifier.cycleDeviceAdjustment('fan', method: 'gesture');
      expect(notifier.getById('fan')!.fanSpeed, 1);
      expect(notifier.getById('fan')!.isOn, isTrue);
      expect(
        await notifier.cycleDeviceAdjustment('ac'),
        contains('ON before adjusting'),
      );
      expect(notifier.getById('ac')!.isOn, isFalse);
      expect(mqtt.commands, ['fan:SPEED_1:gesture']);
    },
  );

  test(
    'Missing values use existing defaults; out-of-range values recover safely',
    () async {
      final defaultFan = Device.fromMap({'id': 'fan', 'type': 'fan'});
      final defaultAc = Device.fromMap({
        'id': 'ac',
        'type': 'ac',
        'isOn': true,
      });
      setup([defaultFan, defaultAc]);
      await notifier.cycleDeviceAdjustment('fan');
      await notifier.cycleDeviceAdjustment('ac');
      expect(notifier.getById('fan')!.fanSpeed, 1);
      expect(notifier.getById('ac')!.acTemperature, 25);
      notifier.receiveUpdate(fan.copyWith(fanSpeed: -3));
      notifier.receiveUpdate(ac.copyWith(acTemperature: 99));
      await notifier.cycleDeviceAdjustment('fan');
      await notifier.cycleDeviceAdjustment('ac');
      expect(notifier.getById('fan')!.fanSpeed, 1);
      expect(notifier.getById('ac')!.acTemperature, 16);
    },
  );

  test('Fresh provider values and types are used on each activation', () async {
    setup([fan]);
    notifier.receiveUpdate(fan.copyWith(fanSpeed: 4));
    await notifier.cycleDeviceAdjustment('fan');
    expect(notifier.getById('fan')!.fanSpeed, 5);
    notifier.receiveUpdate(
      fan.copyWith(type: DeviceType.ac, acTemperature: 30),
    );
    await notifier.cycleDeviceAdjustment('fan');
    expect(notifier.getById('fan')!.acTemperature, 16);
  });

  test(
    'Missing device, lights and sensors never send adjustment commands',
    () async {
      setup([
        fan.copyWith(type: DeviceType.light),
        ac.copyWith(type: DeviceType.sensor),
      ]);
      expect(
        await notifier.cycleDeviceAdjustment('missing'),
        contains('no longer available'),
      );
      expect(
        await notifier.cycleDeviceAdjustment('fan'),
        contains('does not support'),
      );
      expect(
        await notifier.cycleDeviceAdjustment('ac'),
        contains('does not support'),
      );
      expect(mqtt.commands, isEmpty);
    },
  );

  for (final device in [fan, ac]) {
    test(
      'Failed ${device.type} command preserves state and does not log success',
      () async {
        setup([device]);
        mqtt.success = false;
        expect(
          await notifier.cycleDeviceAdjustment(device.id),
          contains('Could not adjust'),
        );
        expect(container.read(devicesProvider).single, device);
        expect(container.read(activityLogProvider), isEmpty);
        mqtt.throws = true;
        await expectLater(
          notifier.cycleDeviceAdjustment(device.id),
          throwsException,
        );
        expect(container.read(devicesProvider).single, device);
      },
    );
  }
}
