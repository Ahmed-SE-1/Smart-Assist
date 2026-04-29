import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/device.dart';
import '../models/room.dart';
import '../models/activity_log.dart';
import '../services/iot_simulation_service.dart';
import 'service_providers.dart';

const _uuid = Uuid();

// ═══════════════════════════════════════════
// ROOM STATE
// ═══════════════════════════════════════════

class RoomsNotifier extends Notifier<List<Room>> {
  int _nodeCounter = 0;
  static const _storageKey = 'saved_rooms_db';

  @override
  List<Room> build() {
    _loadRooms();
    return [];
  }

  Future<void> _loadRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Room.fromMap(e)).toList();
      _nodeCounter = state.length;
    } else {
      _nodeCounter = 3;
      state = const [
        Room(id: 'r1', name: 'Living Room', iconAsset: 'living_room', esp32NodeId: 'NODE_001'),
        Room(id: 'r2', name: 'Bedroom', iconAsset: 'bed', esp32NodeId: 'NODE_002'),
        Room(id: 'r3', name: 'Kitchen', iconAsset: 'kitchen', esp32NodeId: 'NODE_003'),
      ];
      _saveRooms();
    }
  }

  Future<void> _saveRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  /// Add a room (max 5). Returns error string or null on success.
  String? addRoom(String name, String iconAsset) {
    if (name.trim().isEmpty) return 'Room name cannot be empty';
    if (state.length >= 5) return 'Maximum 5 rooms allowed';
    if (state.any((r) => r.name.toLowerCase() == name.trim().toLowerCase())) {
      return 'Room "$name" already exists';
    }

    _nodeCounter++;
    final nodeId = 'NODE_${_nodeCounter.toString().padLeft(3, '0')}';
    final room = Room(
      id: _uuid.v4(),
      name: name.trim(),
      iconAsset: iconAsset,
      esp32NodeId: nodeId,
    );

    state = [...state, room];
    _saveRooms();
    return null;
  }

  String? editRoom(String id, String name, String iconAsset) {
    if (name.trim().isEmpty) return 'Room name cannot be empty';
    if (state.any((r) => r.id != id && r.name.toLowerCase() == name.trim().toLowerCase())) {
      return 'Room "$name" already exists';
    }

    state = state.map((r) {
      if (r.id == id) return r.copyWith(name: name.trim(), iconAsset: iconAsset);
      return r;
    }).toList();
    _saveRooms();
    return null;
  }

  void removeRoom(String roomId) {
    state = state.where((r) => r.id != roomId).toList();
    _saveRooms();
    // Also remove devices in that room
    ref.read(devicesProvider.notifier).removeDevicesInRoom(roomId);
  }
}

final roomsProvider = NotifierProvider<RoomsNotifier, List<Room>>(RoomsNotifier.new);

// ═══════════════════════════════════════════
// DEVICE STATE
// ═══════════════════════════════════════════

class DevicesNotifier extends Notifier<List<Device>> {
  Timer? _sensorTimer;
  static const _storageKey = 'saved_devices_db';

  @override
  List<Device> build() {
    _loadDevices();

    // Start sensor simulation
    _startSensorSimulation();

    ref.onDispose(() {
      _sensorTimer?.cancel();
    });

    return [];
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Device.fromMap(e)).toList();
    } else {
      state = const [
        Device(id: 'd1', name: 'Main Light', type: DeviceType.light, roomId: 'r1', isOn: true),
        Device(id: 'd2', name: 'Ceiling Fan', type: DeviceType.fan, roomId: 'r1', isOn: false, fanSpeed: 0),
        Device(id: 'd3', name: 'Night Lamp', type: DeviceType.light, roomId: 'r2', isOn: false),
        Device(id: 'd4', name: 'AC Unit', type: DeviceType.ac, roomId: 'r2', isOn: true, acTemperature: 24),
        Device(id: 'd5', name: 'Kitchen Light', type: DeviceType.light, roomId: 'r3', isOn: false),
        Device(id: 'd6', name: 'Temp Sensor', type: DeviceType.sensor, roomId: 'r1', sensorValue: 28.0, sensorType: 'temperature'),
        Device(id: 'd7', name: 'Motion Sensor', type: DeviceType.sensor, roomId: 'r3', sensorValue: 0.0, sensorType: 'motion'),
      ];
      _saveDevices();
    }
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((d) => d.toMap()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  void _startSensorSimulation() {
    _sensorTimer?.cancel();
    final iot = IoTSimulationService();
    _sensorTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final currentDevices = state;
      bool changed = false;
      final newDevices = currentDevices.map((d) {
        if (d.type == DeviceType.sensor) {
          final newValue = iot.generateSensorValue(d.sensorType, d.sensorValue);
          if (newValue != d.sensorValue) {
            changed = true;
            return d.copyWith(sensorValue: double.parse(newValue.toStringAsFixed(1)));
          }
        }
        return d;
      }).toList();

      if (changed) {
        state = newDevices;
      }
    });
  }

  /// Add a device to a room.
  String? addDevice(String name, DeviceType type, String roomId) {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    final sensorType = type == DeviceType.sensor ? 'temperature' : 'temperature';
    final device = Device(
      id: _uuid.v4(),
      name: name.trim(),
      type: type,
      roomId: roomId,
      sensorValue: type == DeviceType.sensor ? 25.0 : 0.0,
      sensorType: sensorType,
    );

    state = [...state, device];
    _saveDevices();
    return null;
  }

  String? editDevice(String id, String name, DeviceType type) {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    state = state.map((d) {
      if (d.id == id) return d.copyWith(name: name.trim(), type: type);
      return d;
    }).toList();
    _saveDevices();
    return null;
  }

  /// Add a sensor device with specific sensor type.
  String? addSensorDevice(String name, String roomId, String sensorType) {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    final device = Device(
      id: _uuid.v4(),
      name: name.trim(),
      type: DeviceType.sensor,
      roomId: roomId,
      sensorValue: sensorType == 'temperature' ? 25.0 : 0.0,
      sensorType: sensorType,
    );

    state = [...state, device];
    _saveDevices();
    return null;
  }

  void removeDevice(String deviceId) {
    state = state.where((d) => d.id != deviceId).toList();
    _saveDevices();
  }

  void removeDevicesInRoom(String roomId) {
    state = state.where((d) => d.roomId != roomId).toList();
    _saveDevices();
  }

  /// Core device control: toggle on/off with IoT pipeline simulation.
  Future<bool> toggleDevice(Device device, {String method = 'app'}) async {
    final newState = !device.isOn;
    final mqtt = ref.read(mqttServiceProvider);

    final result = await mqtt.publishCommand(
      device: device,
      action: newState ? 'ON' : 'OFF',
      method: method,
    );

    if (result.success) {
      state = state.map((d) {
        if (d.id == device.id) return d.copyWith(isOn: newState);
        return d;
      }).toList();

      // Log the action
      ref.read(activityLogProvider.notifier).addLog(
        deviceId: device.id,
        deviceName: device.name,
        roomId: device.roomId,
        action: newState ? 'ON' : 'OFF',
        method: method,
      );
    }

    return result.success;
  }

  /// Set fan speed with IoT pipeline simulation.
  Future<bool> setFanSpeed(Device device, int speed, {String method = 'app'}) async {
    final mqtt = ref.read(mqttServiceProvider);

    final result = await mqtt.publishCommand(
      device: device,
      action: 'SPEED_$speed',
      method: method,
    );

    if (result.success) {
      state = state.map((d) {
        if (d.id == device.id) return d.copyWith(fanSpeed: speed, isOn: speed > 0);
        return d;
      }).toList();

      ref.read(activityLogProvider.notifier).addLog(
        deviceId: device.id,
        deviceName: device.name,
        roomId: device.roomId,
        action: 'SPEED_$speed',
        method: method,
      );
    }

    return result.success;
  }

  /// Set AC temperature with IoT pipeline simulation.
  Future<bool> setACTemperature(Device device, int temperature, {String method = 'app'}) async {
    final mqtt = ref.read(mqttServiceProvider);

    final result = await mqtt.publishCommand(
      device: device,
      action: 'TEMP_$temperature',
      method: method,
    );

    if (result.success) {
      state = state.map((d) {
        if (d.id == device.id) return d.copyWith(acTemperature: temperature);
        return d;
      }).toList();

      ref.read(activityLogProvider.notifier).addLog(
        deviceId: device.id,
        deviceName: device.name,
        roomId: device.roomId,
        action: 'TEMP_$temperature',
        method: method,
      );
    }

    return result.success;
  }

  /// Turn a device ON directly (for automation/voice/gesture).
  Future<bool> turnOn(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere((d) => d.id == deviceId, orElse: () => throw Exception('Device not found'));
    if (device.isOn) return true; // Already on
    return toggleDevice(device, method: method);
  }

  /// Turn a device OFF directly (for automation/voice/gesture).
  Future<bool> turnOff(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere((d) => d.id == deviceId, orElse: () => throw Exception('Device not found'));
    if (!device.isOn) return true; // Already off
    return toggleDevice(device, method: method);
  }

  /// Turn off all devices (for gesture fist action).
  Future<void> turnOffAll({String method = 'app'}) async {
    final onDevices = state.where((d) => d.isOn && d.type != DeviceType.sensor).toList();
    for (final device in onDevices) {
      await toggleDevice(device, method: method);
    }
  }

  /// Find devices by name (case-insensitive, partial match).
  List<Device> findByName(String name) {
    final lower = name.toLowerCase();
    return state.where((d) => d.name.toLowerCase().contains(lower)).toList();
  }

  /// Get a device by ID.
  Device? getById(String id) {
    try {
      return state.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }
}

final devicesProvider = NotifierProvider<DevicesNotifier, List<Device>>(DevicesNotifier.new);

// Helper provider to get devices for a specific room
final devicesByRoomProvider = Provider.family<List<Device>, String>((ref, roomId) {
  final devices = ref.watch(devicesProvider);
  return devices.where((d) => d.roomId == roomId).toList();
});

// ═══════════════════════════════════════════
// ACTIVITY LOG STATE
// ═══════════════════════════════════════════

class ActivityLogNotifier extends Notifier<List<ActivityLog>> {
  @override
  List<ActivityLog> build() {
    return [];
  }

  void addLog({
    required String deviceId,
    required String deviceName,
    required String roomId,
    required String action,
    required String method,
  }) {
    final log = ActivityLog(
      id: _uuid.v4(),
      deviceId: deviceId,
      deviceName: deviceName,
      roomId: roomId,
      action: action,
      method: method,
      timestamp: DateTime.now(),
    );

    // Add newest first
    state = [log, ...state];
  }
}

final activityLogProvider = NotifierProvider<ActivityLogNotifier, List<ActivityLog>>(ActivityLogNotifier.new);

// ═══════════════════════════════════════════
// DASHBOARD HELPERS
// ═══════════════════════════════════════════

/// Active (on) device count
final activeDeviceCountProvider = Provider<int>((ref) {
  final devices = ref.watch(devicesProvider);
  return devices.where((d) => d.isOn && d.type != DeviceType.sensor).toList().length;
});

/// Temperature reading from the first temperature sensor found
final temperatureProvider = Provider<double>((ref) {
  final devices = ref.watch(devicesProvider);
  try {
    final sensor = devices.firstWhere((d) => d.type == DeviceType.sensor && d.sensorType == 'temperature');
    return sensor.sensorValue;
  } catch (_) {
    return 0.0;
  }
});
