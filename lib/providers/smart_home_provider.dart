import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/activity_log.dart';
import '../models/device.dart';
import '../models/room.dart';
import '../models/user.dart';
import '../services/iot_simulation_service.dart';
import './user_provider.dart';
import 'automation_provider.dart';
import 'service_providers.dart';

const _uuid = Uuid();

// ═══════════════════════════════════════════
// ROOM STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Manages the list of Rooms (e.g., Bedroom, Kitchen) created by the user.
class RoomsNotifier extends Notifier<List<Room>> {
  int _nodeCounter = 0;

  // --- UPGRADED: House-Specific Storage Key ---
  String getStorageKey() {
    final user = ref.read(userProvider);
    // Agar user logged in hai, toh uske houseId ke hisaab se key banegi
    return 'shared_house_rooms_db_${user?.houseId ?? 'default'}';
  }

  @override
  List<Room> build() {
    // ref.watch lagane se jab bhi user login/logout hoga, ye provider reload hoga
    ref.watch(userProvider);
    Future.microtask(_loadRooms);
    return [];
  }

  Future<void> _loadRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(getStorageKey());
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Room.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  Future<void> _saveRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(getStorageKey(), encoded);
  }

  String? addRoom(String name, String iconAsset, String creatorId, String creatorName) {
    if (name.trim().isEmpty) return 'Room name cannot be empty';
    if (state.length >= 5) return 'Maximum 5 rooms allowed';

    final isDuplicate = state.any((r) => r.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (isDuplicate) {
      return 'Room "$name" already exists. Please choose a different name.';
    }

    _nodeCounter++;
    final nodeId = 'NODE_${_nodeCounter.toString().padLeft(3, '0')}';

    final room = Room(
      id: _uuid.v4(),
      name: name.trim(),
      iconAsset: iconAsset,
      esp32NodeId: nodeId,
      creatorId: creatorId,
      creatorName: creatorName,
    );

    state = [...state, room];
    _saveRooms();
    return null;
  }

  String? editRoom(String id, String name, String iconAsset) {
    if (name.trim().isEmpty) return 'Room name cannot be empty';

    if (state.any((r) => r.id != id && r.name.trim().toLowerCase() == name.trim().toLowerCase())) {
      return 'Room "$name" already exists. Please choose a different name.';
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

final roomsProvider = NotifierProvider<RoomsNotifier, List<Room>>(
  RoomsNotifier.new,
);

// --- ACCESS CONTROL FILTER FOR ROOMS ---
final visibleRoomsProvider = Provider<List<Room>>((ref) {
  final user = ref.watch(userProvider);
  final allRooms = ref.watch(roomsProvider);

  if (user == null) return [];

  if (user.role == UserRole.owner) {
    return allRooms;
  } else {
    return allRooms.where((room) => room.creatorId == user.id).toList();
  }
});

// ═══════════════════════════════════════════
// DEVICE STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Outcome of the existing sequential, per-device OFF operation.
class AllDevicesOffResult {
  const AllDevicesOffResult({
    required this.controllableCount,
    required this.alreadyOffCount,
    required this.turnedOffCount,
    required this.failedCount,
  });

  final int controllableCount;
  final int alreadyOffCount;
  final int turnedOffCount;
  final int failedCount;

  String get message {
    if (controllableCount == 0) return 'No controllable devices found.';
    if (failedCount > 0) {
      return '$turnedOffCount devices turned OFF. '
          '$alreadyOffCount already OFF. '
          '$failedCount devices could not be turned OFF. Please try again.';
    }
    if (alreadyOffCount == controllableCount) {
      return 'All devices are already OFF.';
    }
    return 'All devices have been turned OFF.';
  }
}

class DevicesNotifier extends Notifier<List<Device>> {
  Timer? _sensorTimer;

  // --- UPGRADED: House-Specific Storage Key ---
  String getStorageKey() {
    final user = ref.read(userProvider);
    return 'shared_house_devices_db_${user?.houseId ?? 'default'}';
  }

  @override
  List<Device> build() {
    ref.watch(userProvider); // User switch hone par devices reload hongi
    Future.microtask(_loadDevices);
    _startSensorSimulation();
    ref.onDispose(() {
      _sensorTimer?.cancel();
    });
    return [];
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(getStorageKey());
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => Device.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((d) => d.toMap()).toList());
    await prefs.setString(getStorageKey(), encoded);
  }

  void _startSensorSimulation() {
    _sensorTimer?.cancel();
    final iot = IoTSimulationService();

    _sensorTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final currentDevices = state;
      bool changed = false;

      final newDevices = currentDevices.map((d) {
        if (d.type == DeviceType.sensor) {
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

  void removeDevice(String deviceId) {
    state = state.where((d) => d.id != deviceId).toList();
    _saveDevices();
    ref.read(automationProvider.notifier).removeRulesForDevice(deviceId);
  }

  void removeDevicesInRoom(String roomId) {
    final devicesToRemove = state.where((d) => d.roomId == roomId).toList();

    state = state.where((d) => d.roomId != roomId).toList();
    _saveDevices();

    for (var device in devicesToRemove) {
      ref.read(automationProvider.notifier).removeRulesForDevice(device.id);
    }
  }

  // --- HARDWARE INTERACTION METHODS --- //

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
      _saveDevices();

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
      _saveDevices();

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
      _saveDevices();

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

  /// Cycles the current device value using the same setters as manual controls.
  Future<String> cycleDeviceAdjustment(
    String deviceId, {
    String method = 'app',
  }) async {
    // Resolve by ID at execution time so provider/remote updates are respected.
    final device = getById(deviceId);
    if (device == null) return 'Selected device is no longer available.';

    switch (device.type) {
      case DeviceType.fan:
        final current = device.fanSpeed;
        final next = current < DeviceControlLimits.minRunningFanSpeed ||
                current >= DeviceControlLimits.maxFanSpeed
            ? DeviceControlLimits.minRunningFanSpeed
            : current + DeviceControlLimits.fanSpeedStep;
        // The manual fan slider is active while OFF; its setter handles power.
        final success = await setFanSpeed(device, next, method: method);
        return success
            ? '${device.name} speed set to $next.'
            : 'Could not adjust ${device.name}. Device not responding.';
      case DeviceType.ac:
        // The manual temperature slider is available only while the AC is ON.
        if (!device.isOn) {
          return 'Turn ${device.name} ON before adjusting temperature.';
        }
        final current = device.acTemperature;
        final next = current < DeviceControlLimits.minAcTemperature ||
                current >= DeviceControlLimits.maxAcTemperature
            ? DeviceControlLimits.minAcTemperature
            : current + DeviceControlLimits.acTemperatureStep;
        final success = await setACTemperature(device, next, method: method);
        return success
            ? '${device.name} temperature set to $next degrees.'
            : 'Could not adjust ${device.name}. Device not responding.';
      case DeviceType.light:
      case DeviceType.sensor:
        return 'This device does not support adjustment.';
    }
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

  Future<AllDevicesOffResult> turnOffAll({String method = 'app'}) async {
    // Use the complete house device list, regardless of room selection.
    final devices = state.where((d) => d.type != DeviceType.sensor).toList();
    var alreadyOff = 0;
    var turnedOff = 0;
    var failed = 0;
    for (final device in devices) {
      if (!device.isOn) {
        alreadyOff++;
        continue;
      }
      try {
        // Re-read current state through the same OFF path as other controls.
        // Keep commands sequential, as in the original implementation.
        if (await turnOff(device.id, method: method)) {
          turnedOff++;
        } else {
          failed++;
        }
      } catch (_) {
        // A failed/unavailable device must not prevent the others going OFF.
        failed++;
      }
    }
    return AllDevicesOffResult(
      controllableCount: devices.length,
      alreadyOffCount: alreadyOff,
      turnedOffCount: turnedOff,
      failedCount: failed,
    );
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
    ref.watch(userProvider); // Naya User login par purane logs clear ho jayenge
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

    state = [log, ...state];
  }
}

final activityLogProvider = NotifierProvider<ActivityLogNotifier, List<ActivityLog>>(
  ActivityLogNotifier.new,
);

// ═══════════════════════════════════════════
// DASHBOARD UI HELPERS
// ═══════════════════════════════════════════

final activeDeviceCountProvider = Provider<int>((ref) {
  final devices = ref.watch(devicesProvider);
  return devices.where((d) => d.isOn && d.type != DeviceType.sensor).toList().length;
});

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
