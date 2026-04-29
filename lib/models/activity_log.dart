class ActivityLog {
  final String id;
  final String deviceId;
  final String deviceName;
  final String roomId;
  final String action;       // "ON", "OFF", "SPEED_3", "TEMP_24"
  final String method;       // "app", "voice", "gesture", "automation"
  final DateTime timestamp;

  const ActivityLog({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.roomId,
    required this.action,
    required this.method,
    required this.timestamp,
  });
}
