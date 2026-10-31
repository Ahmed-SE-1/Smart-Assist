import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home/core/mqtt_config.dart';
import 'package:smart_home/models/device.dart';
import 'package:smart_home/models/room.dart';
import 'package:smart_home/models/user.dart';
import 'package:smart_home/providers/service_providers.dart';
import 'package:smart_home/providers/smart_home_provider.dart';
import 'package:smart_home/providers/user_provider.dart';
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
  final published = <Map<String, Object?>>[];
  final simulated = <String>[];
  bool failPublish = false;

  @override
  Future<CommandResult> publishDeviceCommand({
    required String houseId,
    required String mqttDeviceId,
    required int channel,
    required String state,
  }) async {
    published.add({
      'houseId': houseId,
      'nodeId': mqttDeviceId,
      'channel': channel,
      'state': state,
      'topic': MqttService.commandTopic(houseId, mqttDeviceId),
    });
    return CommandResult(
      success: !failPublish,
      deviceId: '',
      roomId: '',
      action: state,
      method: 'mqtt',
      timestamp: DateTime.now(),
      message:
          failPublish
              ? 'MQTT publish failed'
              : 'Command sent to the broker. The ESP32 has not confirmed the relay.',
    );
  }

  @override
  Future<CommandResult> publishCommand({
    required Device device,
    required String action,
    required String method,
  }) async {
    simulated.add('${device.id}:$action:$method');
    return CommandResult(
      success: true,
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

  const savedRoom = {
    'id': 'room-1',
    'name': 'Lounge',
    'iconAsset': 'living_room',
    'esp32NodeId': 'NODE_001',
    'creatorId': 'owner',
    'creatorName': 'Owner',
  };

  test('Room JSON without mqttNodeId still loads', () {
    final room = Room.fromMap(savedRoom);
    expect(room.esp32NodeId, 'NODE_001');
    expect(room.mqttNodeId, isNull);
    expect(room.name, 'Lounge');
  });

  test('Room JSON keeps a supported mqttNodeId and drops an unknown one', () {
    final mapped = Room.fromMap({...savedRoom, 'mqttNodeId': Room.room1NodeId});
    expect(mapped.mqttNodeId, Room.room1NodeId);
    expect(mapped.toMap()['mqttNodeId'], Room.room1NodeId);
    expect(mapped.toMap()['esp32NodeId'], 'NODE_001');

    final unknown = Room.fromMap({...savedRoom, 'mqttNodeId': 'NODE_001'});
    expect(unknown.mqttNodeId, isNull);
    expect(unknown.esp32NodeId, 'NODE_001');
  });

  test('Device JSON without channel stays readable and fills fan or light', () {
    final legacyLight = Device.fromMap({
      'id': 'light-1',
      'name': 'Lamp',
      'type': 'light',
      'roomId': 'room-1',
      'isOn': true,
    });
    expect(legacyLight.channel, RelayChannel.light);
    expect(legacyLight.isOn, isTrue);
    expect(legacyLight.name, 'Lamp');

    final legacyFan = Device.fromMap({
      'id': 'fan-1',
      'name': 'Fan',
      'type': 'fan',
      'roomId': 'room-1',
    });
    expect(legacyFan.channel, RelayChannel.fan);

    final sensor = Device.fromMap({
      'id': 'sensor-1',
      'name': 'Temp',
      'type': 'sensor',
      'roomId': 'room-1',
      'sensorType': 'temperature',
    });
    expect(sensor.channel, isNull);
    expect(sensor.sensorType, 'temperature');

    final stored = Device.fromMap({
      'id': 'light-2',
      'name': 'Lamp',
      'type': 'light',
      'roomId': 'room-1',
      'channel': 2,
    });
    expect(stored.channel, 2);
    expect(stored.toMap()['channel'], 2);
  });

  test('New local node ids continue after the highest saved NODE id', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        roomsProvider.overrideWith(
          () => _Rooms([
            const Room(
              id: 'r1',
              name: 'Existing',
              iconAsset: 'bed',
              esp32NodeId: 'NODE_002',
              creatorId: 'owner',
              creatorName: 'Owner',
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final error = container
        .read(roomsProvider.notifier)
        .addRoom('Kitchen', 'kitchen', 'owner', 'Owner');
    expect(error, isNull);
    final rooms = container.read(roomsProvider);
    expect(rooms.first.esp32NodeId, 'NODE_002');
    expect(rooms.last.esp32NodeId, 'NODE_003');
    expect(rooms.last.mqttNodeId, isNull);
  });

  test('The same ESP32 node cannot be assigned to two rooms', () {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        roomsProvider.overrideWith(
          () => _Rooms([
            const Room(
              id: 'r1',
              name: 'Room 1',
              iconAsset: 'bed',
              esp32NodeId: 'NODE_001',
              mqttNodeId: Room.room1NodeId,
              creatorId: 'owner',
              creatorName: 'Owner',
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    final error = container
        .read(roomsProvider.notifier)
        .addRoom(
          'Room 2',
          'living_room',
          'owner',
          'Owner',
          mqttNodeId: Room.room1NodeId,
        );
    expect(error, contains(Room.room1NodeId));
    expect(container.read(roomsProvider), hasLength(1));
  });

  const mqttOn = MqttConfig(
    enabled: true,
    host: 'broker.example',
    port: 8883,
    username: 'mqtt-user',
    password: 'mqtt-pass',
    testAppDeviceId: 'legacy-light',
    testMqttDeviceId: Room.room1NodeId,
    testChannel: RelayChannel.light,
  );

  late ProviderContainer container;
  late _Mqtt mqtt;

  void setup({
    required List<Room> rooms,
    required List<Device> devices,
    MqttConfig config = mqttOn,
  }) {
    SharedPreferences.setMockInitialValues({});
    mqtt = _Mqtt();
    container = ProviderContainer(
      overrides: [
        roomsProvider.overrideWith(() => _Rooms(rooms)),
        devicesProvider.overrideWith(() => _Devices(devices)),
        mqttServiceProvider.overrideWithValue(mqtt),
        mqttConfigProvider.overrideWithValue(config),
      ],
    );
    container
        .read(userProvider.notifier)
        .setUser(
          User(
            id: 'owner',
            name: 'Owner',
            email: 'owner@example.com',
            houseId: 'house-1',
          ),
        );
    addTearDown(container.dispose);
  }

  Room room(String id, String? nodeId) => Room(
    id: id,
    name: id,
    iconAsset: 'bed',
    esp32NodeId: 'NODE_001',
    mqttNodeId: nodeId,
    creatorId: 'owner',
    creatorName: 'Owner',
  );

  test('Fan ON publishes channel 1 on the room node', () async {
    const fan = Device(
      id: 'fan',
      name: 'Fan',
      type: DeviceType.fan,
      roomId: 'room-1',
      channel: RelayChannel.fan,
    );
    setup(rooms: [room('room-1', Room.room1NodeId)], devices: [fan]);
    final success = await container
        .read(devicesProvider.notifier)
        .toggleDevice(fan);
    expect(success, isTrue);
    expect(mqtt.simulated, isEmpty);
    expect(
      mqtt.published.single['topic'],
      'smartassist/house-1/ROOM1_NODE/cmd',
    );
    expect(mqtt.published.single['channel'], 1);
    expect(mqtt.published.single['state'], 'ON');
    expect(container.read(devicesProvider).single.isOn, isTrue);
  });

  test('Light OFF publishes channel 2 on ROOM2_NODE', () async {
    const light = Device(
      id: 'light',
      name: 'Light',
      type: DeviceType.light,
      roomId: 'room-2',
      isOn: true,
      channel: RelayChannel.light,
    );
    setup(rooms: [room('room-2', Room.room2NodeId)], devices: [light]);
    final success = await container
        .read(devicesProvider.notifier)
        .toggleDevice(light);
    expect(success, isTrue);
    expect(
      mqtt.published.single['topic'],
      'smartassist/house-1/ROOM2_NODE/cmd',
    );
    expect(mqtt.published.single['channel'], 2);
    expect(mqtt.published.single['state'], 'OFF');
  });

  test('An explicit room mapping beats the legacy test device id', () async {
    const light = Device(
      id: 'legacy-light',
      name: 'Light',
      type: DeviceType.light,
      roomId: 'room-2',
      channel: RelayChannel.light,
    );
    setup(rooms: [room('room-2', Room.room2NodeId)], devices: [light]);
    await container.read(devicesProvider.notifier).toggleDevice(light);
    expect(mqtt.published.single['nodeId'], Room.room2NodeId);
    expect(mqtt.published.single['channel'], RelayChannel.light);
  });

  test('An unmapped room does not publish to an invented node', () async {
    const light = Device(
      id: 'light',
      name: 'Light',
      type: DeviceType.light,
      roomId: 'room-1',
      isOn: true,
      channel: RelayChannel.light,
    );
    setup(rooms: [room('room-1', null)], devices: [light]);
    final success = await container
        .read(devicesProvider.notifier)
        .toggleDevice(light);
    expect(success, isFalse);
    expect(mqtt.published, isEmpty);
    expect(mqtt.simulated, isEmpty);
    expect(container.read(devicesProvider).single.isOn, isTrue);
    expect(
      container.read(devicesProvider.notifier).lastCommandMessage,
      contains('not mapped'),
    );
  });

  test('AC and sensor actions do not publish relay commands', () async {
    const ac = Device(
      id: 'ac',
      name: 'AC',
      type: DeviceType.ac,
      roomId: 'room-1',
    );
    const sensor = Device(
      id: 'sensor',
      name: 'Sensor',
      type: DeviceType.sensor,
      roomId: 'room-1',
      isOn: true,
    );
    setup(rooms: [room('room-1', Room.room1NodeId)], devices: [ac, sensor]);
    final notifier = container.read(devicesProvider.notifier);
    expect(await notifier.toggleDevice(ac), isTrue);
    expect(await notifier.toggleDevice(sensor), isTrue);
    expect(await notifier.setFanSpeed(ac, 3), isTrue);
    expect(mqtt.published, isEmpty);
    expect(mqtt.simulated, ['ac:ON:app', 'sensor:OFF:app', 'ac:SPEED_3:app']);
  });

  test('Fan speed is not published as an ESP32 command', () async {
    const fan = Device(
      id: 'fan',
      name: 'Fan',
      type: DeviceType.fan,
      roomId: 'room-1',
      channel: RelayChannel.fan,
      isOn: true,
      fanSpeed: 1,
    );
    setup(rooms: [room('room-1', Room.room1NodeId)], devices: [fan]);
    final success = await container
        .read(devicesProvider.notifier)
        .setFanSpeed(fan, 3, method: 'gesture');
    expect(success, isTrue);
    expect(mqtt.published, isEmpty);
    expect(mqtt.simulated, ['fan:SPEED_3:gesture']);
  });

  test('A publish failure does not mark the command successful', () async {
    const light = Device(
      id: 'light',
      name: 'Light',
      type: DeviceType.light,
      roomId: 'room-1',
      channel: RelayChannel.light,
    );
    setup(rooms: [room('room-1', Room.room1NodeId)], devices: [light]);
    mqtt.failPublish = true;
    final success = await container
        .read(devicesProvider.notifier)
        .toggleDevice(light);
    expect(success, isFalse);
    expect(container.read(devicesProvider).single.isOn, isFalse);
    expect(container.read(activityLogProvider), isEmpty);
    expect(
      container.read(devicesProvider.notifier).lastCommandMessage,
      'MQTT publish failed',
    );
  });

  test('Changing a fan to an AC clears its relay channel', () {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        devicesProvider.overrideWith(
          () => _Devices([
            const Device(
              id: 'fan',
              name: 'Fan',
              type: DeviceType.fan,
              roomId: 'room-1',
              channel: RelayChannel.fan,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(devicesProvider.notifier)
        .editDevice('fan', 'Cooling', DeviceType.ac);
    final device = container.read(devicesProvider).single;
    expect(device.type, DeviceType.ac);
    expect(device.channel, isNull);
  });

  test('MQTT payload and topic use the firmware contract', () {
    expect(
      MqttService.commandTopic('house-1', Room.room1NodeId),
      'smartassist/house-1/ROOM1_NODE/cmd',
    );
    expect(
      MqttService.commandTopic('house-1', Room.room2NodeId),
      'smartassist/house-1/ROOM2_NODE/cmd',
    );
    final payload = MqttService.commandPayload(
      cmdId: 'cmd-1',
      channel: RelayChannel.fan,
      state: 'ON',
    );
    expect(payload.keys, ['cmdId', 'channel', 'state']);
    expect(payload['channel'], 1);
    expect(payload.containsKey('ts'), isFalse);
  });

  test(
    'Invalid house, node, channel, and state are rejected before connect',
    () async {
      final service = MqttService(
        config: const MqttConfig(
          enabled: true,
          host: 'broker.example',
          username: 'mqtt-user',
          password: 'mqtt-pass',
        ),
      );
      addTearDown(service.dispose);

      final missingHouse = await service.publishDeviceCommand(
        houseId: ' ',
        mqttDeviceId: Room.room1NodeId,
        channel: 1,
        state: 'ON',
      );
      final badNode = await service.publishDeviceCommand(
        houseId: 'house-1',
        mqttDeviceId: 'NODE_001',
        channel: 1,
        state: 'ON',
      );
      final badChannel = await service.publishDeviceCommand(
        houseId: 'house-1',
        mqttDeviceId: Room.room1NodeId,
        channel: 0,
        state: 'ON',
      );
      final badState = await service.publishDeviceCommand(
        houseId: 'house-1',
        mqttDeviceId: Room.room2NodeId,
        channel: 2,
        state: 'SPEED_3',
      );

      expect(missingHouse.success, isFalse);
      expect(badNode.success, isFalse);
      expect(badNode.message, contains('ROOM1_NODE'));
      expect(badChannel.success, isFalse);
      expect(badChannel.message, contains('channel'));
      expect(badState.success, isFalse);
      expect(badState.message, contains('ON or OFF'));
      expect(service.isConnected, isFalse);
    },
  );

  test('Configured client ids are unique per session suffix', () {
    const suffix = 'session-a';
    expect(
      MqttService.resolveClientId(configured: '', sessionSuffix: suffix),
      'smartassist-flutter-$suffix',
    );
    expect(
      MqttService.resolveClientId(configured: 'phone', sessionSuffix: suffix),
      'phone-$suffix',
    );
    expect(
      MqttService.resolveClientId(
        configured: 'phone',
        sessionSuffix: 'session-b',
      ),
      isNot(
        MqttService.resolveClientId(configured: 'phone', sessionSuffix: suffix),
      ),
    );
  });
}
