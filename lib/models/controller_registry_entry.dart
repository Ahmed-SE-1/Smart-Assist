import 'package:cloud_firestore/cloud_firestore.dart';

/// Registry metadata for a physical Main ESP32 controller.
///
/// [controllerId] is an opaque physical identity and is deliberately separate
/// from room MQTT node names and MAC addresses.
class ControllerRegistryEntry {
  const ControllerRegistryEntry({
    required this.controllerId,
    this.activeHouseId,
    this.status = 'unknown',
    this.pairedAt,
    this.lastSeenAt,
  });

  final String controllerId;
  final String? activeHouseId;
  final String status;
  final DateTime? pairedAt;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toMap() => {
    'controllerId': controllerId,
    'activeHouseId': activeHouseId,
    'status': status,
    'pairedAt': _timestamp(pairedAt),
    'lastSeenAt': _timestamp(lastSeenAt),
  };

  factory ControllerRegistryEntry.fromMap(
    Map<String, dynamic> map, {
    String? documentId,
  }) {
    return ControllerRegistryEntry(
      controllerId: _requiredString(map, 'controllerId', fallback: documentId),
      activeHouseId: _optionalString(map['activeHouseId']),
      status: map['status'] is String ? map['status'] as String : 'unknown',
      pairedAt: _readDateTime(map['pairedAt']),
      lastSeenAt: _readDateTime(map['lastSeenAt']),
    );
  }

  static Timestamp? _timestamp(DateTime? value) =>
      value == null ? null : Timestamp.fromDate(value);

  static DateTime? _readDateTime(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  static String _requiredString(
    Map<String, dynamic> map,
    String key, {
    String? fallback,
  }) {
    final value = map[key] ?? fallback;
    if (value is String && value.trim().isNotEmpty) return value;
    throw FormatException('Controller field "$key" must be a non-empty string.');
  }

  static String? _optionalString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
