import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
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
// ROOM STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Manages the list of Rooms (e.g., Bedroom, Kitchen) created by the user.
class RoomsNotifier extends Notifier<List<Room>> {
  int _nodeCounter =
      0; // Used to generate fake ESP32 Node IDs for hardware simulation

  /// Generates a storage key tied to the specific logged-in user.
  String getStorageKey(String uid) => '${uid}_saved_rooms_db';

  @override
  List<Room> build() {
    // 1. Identify which user is logged in
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';

    // 2. Fetch their specific rooms from memory asynchronously
    _loadRooms(uid);

    // Return an empty list initially while loading happens
    return [];
  }

  /// Parses saved JSON into a List of Room objects.
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

  /// Converts the current List of Rooms into JSON and saves it.
  Future<void> _saveRooms() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(getStorageKey(uid), encoded);
  }

  /// Validates and adds a new room. Returns an error string if validation fails.
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
      esp32NodeId: nodeId, // Assign a mock hardware node ID
    );

    state = [...state, room];
    _saveRooms();
    return null;
  }

  String? editRoom(String id, String name, String iconAsset) {
    if (name.trim().isEmpty) return 'Room name cannot be empty';
    if (state.any(
      (r) => r.id != id && r.name.toLowerCase() == name.trim().toLowerCase(),
    )) {
      return 'Room "$name" already exists';
    }

    state =
        state.map((r) {
          if (r.id == id)
            return r.copyWith(name: name.trim(), iconAsset: iconAsset);
          return r;
        }).toList();
    _saveRooms();
    return null;
  }

  /// Deletes a room AND cascade-deletes all devices inside that room.
  void removeRoom(String roomId) {
    state = state.where((r) => r.id != roomId).toList();
    _saveRooms();

    // CRITICAL: Call the devices provider to delete orphan devices
    ref.read(devicesProvider.notifier).removeDevicesInRoom(roomId);
  }
}

final roomsProvider = NotifierProvider<RoomsNotifier, List<Room>>(
  RoomsNotifier.new,
);

// ═══════════════════════════════════════════
// DEVICE STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Manages all smart devices (Lights, Fans, ACs, Sensors).
/// This is the most complex provider as it handles IoT simulation and MQTT publishing.
class DevicesNotifier extends Notifier<List<Device>> {
  Timer? _sensorTimer;

  String getStorageKey(String uid) => '${uid}_saved_devices_db';

  @override
  List<Device> build() {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';

    // 1. Load devices asynchronously
    _loadDevices(uid);

    // 2. Start the simulation that randomly fluctuates sensor values (like real temperature)
    _startSensorSimulation();

    // Clean up timers to prevent memory leaks
    ref.onDispose(() {
      _sensorTimer?.cancel();
    });

    return [];
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

  /// A background loop that updates 'sensor' devices (like thermometers) with random noise
  /// every 4 seconds to make the app feel alive.
  void _startSensorSimulation() {
    _sensorTimer?.cancel();
    final iot = IoTSimulationService();

    _sensorTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final currentDevices = state;
      bool changed = false;

      final newDevices =
          currentDevices.map((d) {
            if (d.type == DeviceType.sensor) {
              // Get a new random value slightly deviating from the current one
              final newValue = iot.generateSensorValue(
                d.sensorType,
                d.sensorValue,
              );
              if (newValue != d.sensorValue) {
                changed = true;
                return d.copyWith(
                  sensorValue: double.parse(newValue.toStringAsFixed(1)),
                );
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

    final sensorType =
        type == DeviceType.sensor ? 'temperature' : 'temperature';
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

    state =
        state.map((d) {
          if (d.id == id) return d.copyWith(name: name.trim(), type: type);
          return d;
        }).toList();
    _saveDevices();
    return null;
  }

  void removeDevice(String deviceId) {
    state = state.where((d) => d.id != deviceId).toList();
    _saveDevices();

    // CRITICAL: Cascade delete - remove any automation rules monitoring this device
    ref.read(automationProvider.notifier).removeRulesForDevice(deviceId);
  }

  /// Deletes all devices that belong to a specific room.
  /// Called automatically when a room is deleted.
  void removeDevicesInRoom(String roomId) {
    final devicesToRemove = state.where((d) => d.roomId == roomId).toList();

    state = state.where((d) => d.roomId != roomId).toList();
    _saveDevices();

    // Delete automation rules for all these deleted devices
    for (var device in devicesToRemove) {
      ref.read(automationProvider.notifier).removeRulesForDevice(device.id);
    }
  }

  // --- HARDWARE INTERACTION METHODS --- //

  /// Toggles the physical ON/OFF state of a device by sending a mock MQTT command.
  Future<bool> toggleDevice(Device device, {String method = 'app'}) async {
    final newState = !device.isOn;
    final mqtt = ref.read(mqttServiceProvider);

    // 1. Send command to the mock backend
    final result = await mqtt.publishCommand(
      device: device,
      action: newState ? 'ON' : 'OFF',
      method: method,
    );

    // 2. If the hardware acknowledged the command, update the UI
    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id) return d.copyWith(isOn: newState);
            return d;
          }).toList();
      _saveDevices();

      // 3. Log the action in the global activity history
      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: newState ? 'ON' : 'OFF',
            method: method,
          );
    }
    return result.success;
  }

  Future<bool> setFanSpeed(
    Device device,
    int speed, {
    String method = 'app',
  }) async {
    final mqtt = ref.read(mqttServiceProvider);
    final result = await mqtt.publishCommand(
      device: device,
      action: 'SPEED_$speed',
      method: method,
    );

    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id)
              return d.copyWith(
                fanSpeed: speed,
                isOn: speed > 0,
              ); // Speed > 0 means Fan is ON
            return d;
          }).toList();
      _saveDevices();

      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: 'SPEED_$speed',
            method: method,
          );
    }
    return result.success;
  }

  Future<bool> setACTemperature(
    Device device,
    int temperature, {
    String method = 'app',
  }) async {
    final mqtt = ref.read(mqttServiceProvider);
    final result = await mqtt.publishCommand(
      device: device,
      action: 'TEMP_$temperature',
      method: method,
    );

    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id)
              return d.copyWith(acTemperature: temperature);
            return d;
          }).toList();
      _saveDevices();

      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: 'TEMP_$temperature',
            method: method,
          );
    }
    return result.success;
  }

  // --- HELPERS --- //

  Future<bool> turnOn(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => throw Exception('Device not found'),
    );
    if (device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<bool> turnOff(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => throw Exception('Device not found'),
    );
    if (!device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<void> turnOffAll({String method = 'app'}) async {
    final onDevices =
        state.where((d) => d.isOn && d.type != DeviceType.sensor).toList();
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

final devicesProvider = NotifierProvider<DevicesNotifier, List<Device>>(
  DevicesNotifier.new,
);

/// Helper Provider: Returns only the devices that belong to a specific roomId.
/// Useful for building UI inside a Room Detail screen.
final devicesByRoomProvider = Provider.family<List<Device>, String>((
  ref,
  roomId,
) {
  final devices = ref.watch(devicesProvider);
  return devices.where((d) => d.roomId == roomId).toList();
});

// ═══════════════════════════════════════════
// ACTIVITY LOG STATE
// ═══════════════════════════════════════════

/// Manages the history of all actions performed in the smart home (e.g., "Fan turned on via Voice").
class ActivityLogNotifier extends Notifier<List<ActivityLog>> {
  @override
  List<ActivityLog> build() {
    return []; // Logs are kept purely in RAM right now and clear on restart.
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

    // Insert newest log at the top of the list
    state = [log, ...state];
  }
}

final activityLogProvider =
    NotifierProvider<ActivityLogNotifier, List<ActivityLog>>(
      ActivityLogNotifier.new,
    );

// ═══════════════════════════════════════════
// DASHBOARD UI HELPERS
// ═══════════════════════════════════════════

/// Calculates how many devices are currently ON (ignoring sensors). Used for dashboard stats.
final activeDeviceCountProvider = Provider<int>((ref) {
  final devices = ref.watch(devicesProvider);
  return devices
      .where((d) => d.isOn && d.type != DeviceType.sensor)
      .toList()
      .length;
});

/// Fetches the current temperature reading from the first available temperature sensor.
/// Defaults to 0.0 if no sensors are installed.
final temperatureProvider = Provider<double>((ref) {
  final devices = ref.watch(devicesProvider);
  try {
    final sensor = devices.firstWhere(
      (d) => d.type == DeviceType.sensor && d.sensorType == 'temperature',
    );
    return sensor.sensorValue;
  } catch (_) {
    return 0.0;
  }
});
