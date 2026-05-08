import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart'; // NAYA: Firebase Auth Import
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/activity_log.dart';
import '../models/device.dart';
import '../models/room.dart';
import '../services/iot_simulation_service.dart';
import 'automation_provider.dart';
import 'service_providers.dart';

const _uuid = Uuid();

// ═══════════════════════════════════════════
// ROOM STATE
// ═══════════════════════════════════════════

class RoomsNotifier extends Notifier<List<Room>> {
  int _nodeCounter = 0;

  String getStorageKey(String uid) => '${uid}_saved_rooms_db';

  @override
  List<Room> build() {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';
    _loadRooms(uid);
    return [];
  }

  Future<void> _loadRooms(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(getStorageKey(uid));
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Room.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  Future<void> _saveRooms() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(getStorageKey(uid), encoded);
  }

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
    ref.read(devicesProvider.notifier).removeDevicesInRoom(roomId);
  }
}

final roomsProvider = NotifierProvider<RoomsNotifier, List<Room>>(RoomsNotifier.new);

// ═══════════════════════════════════════════
// DEVICE STATE
// ═══════════════════════════════════════════

class DevicesNotifier extends Notifier<List<Device>> {
  Timer? _sensorTimer;

  // KEY LOGIC: Isay build ke andar use karenge
  String getStorageKey(String uid) => '${uid}_saved_devices_db';

  @override
  List<Device> build() {
    // 1. User ki ID ko watch karein
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';

    // 2. Devices load karein (Async load)
    _loadDevices(uid);

    // 3. Sensor simulation start karein
    _startSensorSimulation();

    ref.onDispose(() {
      _sensorTimer?.cancel();
    });

    return []; // Start with empty, then _loadDevices updates state
  }

  Future<void> _loadDevices(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(getStorageKey(uid));

    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Device.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  Future<void> _saveDevices() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((d) => d.toMap()).toList());
    await prefs.setString(getStorageKey(uid), encoded);
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
    _saveDevices(); // Yaad se save
    return null;
  }

  String? editDevice(String id, String name, DeviceType type) {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    state = state.map((d) {
      if (d.id == id) return d.copyWith(name: name.trim(), type: type);
      return d;
    }).toList();
    _saveDevices(); // Yaad se save
    return null;
  }

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
    _saveDevices(); // Yaad se save
    return null;
  }

  void removeDevice(String deviceId) {
    state = state.where((d) => d.id != deviceId).toList();
    _saveDevices();

    // NAYA: Jab device delete ho toh Automation se bhi uske rules nikal do
    ref.read(automationProvider.notifier).removeRulesForDevice(deviceId);
  }

  void removeDevicesInRoom(String roomId) {
    // Pehle un devices ko dhundo jo delete hone wali hain
    final devicesToRemove = state.where((d) => d.roomId == roomId).toList();

    // Phir unko list mein se nikal do
    state = state.where((d) => d.roomId != roomId).toList();
    _saveDevices();

    // NAYA: Jo devices delete hui hain, unke sab automation rules delete kardo
    for (var device in devicesToRemove) {
      ref.read(automationProvider.notifier).removeRulesForDevice(device.id);
    }
  }

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
      _saveDevices(); // NAYA: Toggle hone par ab local storage update hogi!

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

  Future<bool> setFanSpeed(Device device, int speed, {String method = 'app'}) async {
    final mqtt = ref.read(mqttServiceProvider);
    final result = await mqtt.publishCommand(device: device, action: 'SPEED_$speed', method: method);

    if (result.success) {
      state = state.map((d) {
        if (d.id == device.id) return d.copyWith(fanSpeed: speed, isOn: speed > 0);
        return d;
      }).toList();
      _saveDevices(); // NAYA: Fan speed change hone par save hogi

      ref.read(activityLogProvider.notifier).addLog(
        deviceId: device.id, deviceName: device.name, roomId: device.roomId, action: 'SPEED_$speed', method: method,
      );
    }
    return result.success;
  }

  Future<bool> setACTemperature(Device device, int temperature, {String method = 'app'}) async {
    final mqtt = ref.read(mqttServiceProvider);
    final result = await mqtt.publishCommand(device: device, action: 'TEMP_$temperature', method: method);

    if (result.success) {
      state = state.map((d) {
        if (d.id == device.id) return d.copyWith(acTemperature: temperature);
        return d;
      }).toList();
      _saveDevices(); // NAYA: AC temp change hone par save hogi

      ref.read(activityLogProvider.notifier).addLog(
        deviceId: device.id, deviceName: device.name, roomId: device.roomId, action: 'TEMP_$temperature', method: method,
      );
    }
    return result.success;
  }

  Future<bool> turnOn(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere((d) => d.id == deviceId, orElse: () => throw Exception('Device not found'));
    if (device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<bool> turnOff(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere((d) => d.id == deviceId, orElse: () => throw Exception('Device not found'));
    if (!device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<void> turnOffAll({String method = 'app'}) async {
    final onDevices = state.where((d) => d.isOn && d.type != DeviceType.sensor).toList();
    for (final device in onDevices) {
      await toggleDevice(device, method: method);
    }
  }

  List<Device> findByName(String name) {
    final lower = name.toLowerCase();
    return state.where((d) => d.name.toLowerCase().contains(lower)).toList();
  }

  Device? getById(String id) {
    try {
      return state.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }
}

final devicesProvider = NotifierProvider<DevicesNotifier, List<Device>>(DevicesNotifier.new);

// Helper provider
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