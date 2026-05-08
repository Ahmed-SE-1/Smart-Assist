import 'dart:async';
import 'dart:math';

/// Simulates the full physical IoT architecture.
/// In a real app, this file would be replaced by HTTP or MQTT calls to a backend.
/// Here, it mocks the network journey: App -> MQTT Broker -> Raspberry Pi -> ESP32 Node.
class IoTSimulationService {
  // Singleton pattern: Ensures only one instance of the simulation exists in the app.
  static final IoTSimulationService _instance =
      IoTSimulationService._internal();
  factory IoTSimulationService() => _instance;
  IoTSimulationService._internal();

  final _random = Random();

  /// Simulates sending a command to physical hardware and waiting for a response.
  /// Returns a [CommandResult] after simulating network and processing delays.
  Future<CommandResult> sendCommand({
    required String deviceId,
    required String roomId,
    required String action,
    required String method,
  }) async {
    // Step 1: Simulate the time it takes for the App to reach the MQTT broker via WiFi/4G
    await Future.delayed(const Duration(milliseconds: 300));

    // Step 2: Simulate the Raspberry Pi processing the command and sending it to the ESP32
    await Future.delayed(const Duration(milliseconds: 200));

    // Step 3: Simulate real-world unreliability.
    // There is a 5% chance the hardware fails to respond (e.g., node disconnected).
    final success = _random.nextDouble() > 0.05;

    return CommandResult(
      success: success,
      deviceId: deviceId,
      roomId: roomId,
      action: action,
      method: method,
      timestamp: DateTime.now(),
      message:
          success ? null : 'Device not responding', // Error message if it fails
    );
  }

  /// Generates a fluctuating, realistic sensor value to make the UI feel alive.
  /// This is called periodically by the `DevicesNotifier` in `smart_home_provider.dart`.
  double generateSensorValue(String sensorType, double currentValue) {
    if (sensorType == 'motion') {
      // Motion sensors: 30% chance to detect motion (returns 1.0), otherwise 0.0
      return _random.nextDouble() > 0.7 ? 1.0 : 0.0;
    }

    // Temperature sensors: Fluctuate the current temperature up or down by max 1.5 degrees.
    // Clamped between 18.0°C and 40.0°C so it doesn't drop to freezing or boiling randomly.
    final delta = (_random.nextDouble() * 3.0) - 1.5;
    return (currentValue + delta).clamp(18.0, 40.0);
  }
}

/// A standard response format returning from physical hardware.
class CommandResult {
  final bool success; // Did the hardware execute the command?
  final String deviceId;
  final String roomId;
  final String action; // e.g., 'ON', 'OFF', 'SPEED_3'
  final String method; // e.g., 'voice', 'app', 'gesture', 'automation'
  final DateTime timestamp;
  final String? message; // Optional error message

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
