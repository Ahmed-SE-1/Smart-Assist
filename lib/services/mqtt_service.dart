import 'dart:async';
import '../models/device.dart';
import 'iot_simulation_service.dart';

/// Simulates a real-time MQTT connection for IoT devices.
/// Wraps the IoTSimulationService to provide stream-based updates.
class MqttService {
  final _deviceStateController = StreamController<Device>.broadcast();
  final IoTSimulationService _iot = IoTSimulationService();
  bool _connected = false;

  Stream<Device> get deviceStateUpdates => _deviceStateController.stream;
  bool get isConnected => _connected;

  Future<void> connect() async {
    await Future.delayed(const Duration(seconds: 1));
    _connected = true;
  }

  /// Publishes a device toggle through the simulated IoT pipeline.
  /// Returns a [CommandResult] with success/failure info.
  Future<CommandResult> publishDeviceToggle(Device device, bool newState) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: newState ? 'ON' : 'OFF',
      method: 'app',
    );

    if (result.success) {
      _deviceStateController.add(device.copyWith(isOn: newState));
    }

    return result;
  }

  /// Publishes a fan speed change through the simulated IoT pipeline.
  Future<CommandResult> publishFanSpeed(Device device, int speed) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: 'SPEED_$speed',
      method: 'app',
    );

    if (result.success) {
      _deviceStateController.add(device.copyWith(
        fanSpeed: speed,
        isOn: speed > 0,
      ));
    }

    return result;
  }

  /// Publishes an AC temperature change through the simulated IoT pipeline.
  Future<CommandResult> publishACTemperature(Device device, int temperature) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: 'TEMP_$temperature',
      method: 'app',
    );

    if (result.success) {
      _deviceStateController.add(device.copyWith(acTemperature: temperature));
    }

    return result;
  }

  /// Generic command for voice/gesture/automation control methods.
  Future<CommandResult> publishCommand({
    required Device device,
    required String action,
    required String method,
  }) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: action,
      method: method,
    );

    if (result.success) {
      if (action == 'ON') {
        _deviceStateController.add(device.copyWith(isOn: true));
      } else if (action == 'OFF') {
        _deviceStateController.add(device.copyWith(isOn: false));
      } else if (action.startsWith('SPEED_')) {
        final speed = int.tryParse(action.replaceFirst('SPEED_', '')) ?? 0;
        _deviceStateController.add(device.copyWith(fanSpeed: speed, isOn: speed > 0));
      } else if (action.startsWith('TEMP_')) {
        final temp = int.tryParse(action.replaceFirst('TEMP_', '')) ?? 24;
        _deviceStateController.add(device.copyWith(acTemperature: temp));
      }
    }

    return result;
  }

  void dispose() {
    _deviceStateController.close();
  }
}
