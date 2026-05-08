import 'dart:async';
import '../models/device.dart';
import 'iot_simulation_service.dart';

/// Simulates a real-time MQTT connection for IoT devices.
/// In a real app, this would connect to a broker (like Mosquitto) running on the Raspberry Pi Hub.
/// Here, it wraps the [IoTSimulationService] to provide stream-based updates to the UI.
class MqttService {
  // A broadcast stream that the UI can listen to for instant device state updates.
  final _deviceStateController = StreamController<Device>.broadcast();

  // The mock backend that simulates network delay and physical hardware.
  final IoTSimulationService _iot = IoTSimulationService();

  bool _connected = false;

  /// Exposes the stream of device updates for Riverpod to listen to.
  Stream<Device> get deviceStateUpdates => _deviceStateController.stream;

  /// Returns true if the mock MQTT broker is connected.
  bool get isConnected => _connected;

  /// Simulates connecting to the MQTT Broker with a 1-second delay.
  Future<void> connect() async {
    await Future.delayed(const Duration(seconds: 1));
    _connected = true;
  }

  /// Publishes a simple ON/OFF toggle command to the simulated IoT pipeline.
  /// Returns a [CommandResult] indicating if the hardware accepted the command.
  Future<CommandResult> publishDeviceToggle(
    Device device,
    bool newState,
  ) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: newState ? 'ON' : 'OFF',
      method: 'app',
    );

    // If the hardware processed it successfully, broadcast the new state to the UI.
    if (result.success) {
      _deviceStateController.add(device.copyWith(isOn: newState));
    }

    return result;
  }

  /// Publishes a fan speed change command (e.g., 'SPEED_3') through the simulated pipeline.
  Future<CommandResult> publishFanSpeed(Device device, int speed) async {
    final result = await _iot.sendCommand(
      deviceId: device.id,
      roomId: device.roomId,
      action: 'SPEED_$speed',
      method: 'app',
    );

    if (result.success) {
      _deviceStateController.add(
        device.copyWith(
          fanSpeed: speed,
          isOn: speed > 0, // Automatically turn ON if speed > 0
        ),
      );
    }

    return result;
  }

  /// Publishes an AC temperature change command (e.g., 'TEMP_24') through the simulated pipeline.
  Future<CommandResult> publishACTemperature(
    Device device,
    int temperature,
  ) async {
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

  /// A generic command publisher used heavily by Voice, Gesture, and Automation methods.
  /// It parses the raw action string ('ON', 'OFF', 'SPEED_X', 'TEMP_X') and updates the stream.
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
        _deviceStateController.add(
          device.copyWith(fanSpeed: speed, isOn: speed > 0),
        );
      } else if (action.startsWith('TEMP_')) {
        final temp = int.tryParse(action.replaceFirst('TEMP_', '')) ?? 24;
        _deviceStateController.add(device.copyWith(acTemperature: temp));
      }
    }

    return result;
  }

  /// Closes the stream when the service is destroyed to prevent memory leaks.
  void dispose() {
    _deviceStateController.close();
  }
}
