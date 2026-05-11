import 'dart:async';
import '../models/device.dart';
import 'iot_simulation_service.dart';

/// Simulates a real-time MQTT connection for IoT devices.
/// In a real app, this would connect to a broker (like Mosquitto) running on the Raspberry Pi Hub.
/// Here, it wraps the [IoTSimulationService] to provide stream-based updates to the UI.
class MqttService {
  // The mock backend that simulates network delay and physical hardware.
  final IoTSimulationService _iot = IoTSimulationService();

  /// Simulates connecting to the MQTT Broker with a 1-second delay.
  Future<void> connect() async {
    await Future.delayed(const Duration(seconds: 1));
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

    return result;
  }

  /// Closes the service when destroyed to prevent memory leaks.
  void dispose() {}
}
