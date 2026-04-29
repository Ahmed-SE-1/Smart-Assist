import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/smart_alert.dart';
import '../models/activity_log.dart';
import 'smart_home_provider.dart';

/// Generates alerts from activity logs and sensor data.
final alertsProvider = Provider<List<SmartAlert>>((ref) {
  final logs = ref.watch(activityLogProvider);
  final devices = ref.watch(devicesProvider);

  final alerts = <SmartAlert>[];

  // Generate alerts from automation-triggered logs
  for (final log in logs.take(20)) {
    if (log.method == 'automation') {
      alerts.add(SmartAlert(
        id: 'alert_${log.id}',
        title: '${log.deviceName} ${log.action}',
        description: 'Automation triggered: ${log.deviceName} was turned ${log.action} automatically.',
        timestamp: log.timestamp,
        severity: AlertSeverity.info,
      ));
    }
  }

  // Generate alerts from sensor data
  for (final device in devices) {
    if (device.type.name == 'sensor') {
      if (device.sensorType == 'temperature' && device.sensorValue > 35) {
        alerts.add(SmartAlert(
          id: 'temp_alert_${device.id}',
          title: 'High Temperature Warning',
          description: '${device.name} reading ${device.sensorValue.toStringAsFixed(1)}°C — above safe threshold.',
          timestamp: DateTime.now(),
          severity: AlertSeverity.warning,
        ));
      }
      if (device.sensorType == 'motion' && device.sensorValue > 0.5) {
        alerts.add(SmartAlert(
          id: 'motion_alert_${device.id}',
          title: 'Motion Detected',
          description: '${device.name} detected movement.',
          timestamp: DateTime.now(),
          severity: AlertSeverity.warning,
        ));
      }
    }
  }

  // Add some static alerts if no dynamic ones exist
  if (alerts.isEmpty) {
    alerts.addAll([
      SmartAlert(
        id: 'a1',
        title: 'System Online',
        description: 'All devices are connected and responding normally.',
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        severity: AlertSeverity.info,
      ),
      SmartAlert(
        id: 'a2',
        title: 'Hub Connected',
        description: 'Raspberry Pi hub is online and monitoring.',
        timestamp: DateTime.now().subtract(const Duration(hours: 1)),
        severity: AlertSeverity.info,
      ),
    ]);
  }

  // Sort newest first
  alerts.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return alerts;
});
