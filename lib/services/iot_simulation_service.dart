import 'dart:async';
import 'dart:math';
import '../models/device.dart';

/// Simulates the full IoT pipeline: App → MQTT → Raspberry Pi → ESP32
class IoTSimulationService {
  static final IoTSimulationService _instance = IoTSimulationService._internal();
  factory IoTSimulationService() => _instance;
  IoTSimulationService._internal();

  final _random = Random();

  /// Simulates sending a command through the IoT pipeline.
  /// Returns a [CommandResult] after simulating network + processing delay.
  /// 5% random failure rate.
  Future<CommandResult> sendCommand({
    required String deviceId,
    required String roomId,
    required String action,
    required String method,
  }) async {
    // Step 1: Simulate App → MQTT broker (network delay)
    await Future.delayed(const Duration(milliseconds: 300));

    // Step 2: Simulate MQTT → Raspberry Pi → ESP32 (processing delay)
    await Future.delayed(const Duration(milliseconds: 200));

    // Step 3: 5% random failure
    final success = _random.nextDouble() > 0.05;

    return CommandResult(
      success: success,
      deviceId: deviceId,
      roomId: roomId,
      action: action,
      method: method,
      timestamp: DateTime.now(),
      message: success ? null : 'Device not responding',
    );
  }

  /// Generates a fluctuating sensor value.
  /// For temperature sensors: fluctuates around a base value (22-35°C).
  /// For motion sensors: randomly triggers (returns 1.0 for motion, 0.0 for none).
  double generateSensorValue(String sensorType, double currentValue) {
    if (sensorType == 'motion') {
      return _random.nextDouble() > 0.7 ? 1.0 : 0.0;
    }
    // Temperature: fluctuate ±1.5 around current value, clamped 18-40
    final delta = (_random.nextDouble() * 3.0) - 1.5;
    return (currentValue + delta).clamp(18.0, 40.0);
  }
}

class CommandResult {
  final bool success;
  final String deviceId;
  final String roomId;
  final String action;
  final String method;
  final DateTime timestamp;
  final String? message;

  const CommandResult({
    required this.success,
    required this.deviceId,
    required this.roomId,
    required this.action,
    required this.method,
    required this.timestamp,
    this.message,
  });
}
