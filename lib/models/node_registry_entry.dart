import 'package:cloud_firestore/cloud_firestore.dart';

/// Registry metadata for a physical room Node managed by a Main ESP32.
///
/// This [nodeId] identifies physical hardware; it is not `ROOM1_NODE` or
/// `ROOM2_NODE`, which remain MQTT routing identifiers in the current app.
class NodeRegistryEntry {
  const NodeRegistryEntry({
    required this.nodeId,
    this.controllerId,
    this.houseId,
    this.roomId,
    this.status = 'unknown',
    this.pairedAt,
    this.lastSeenAt,
  });

  final String nodeId;
  final String? controllerId;
  final String? houseId;
  final String? roomId;
  final String status;
  final DateTime? pairedAt;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toMap() => {
    'nodeId': nodeId,
    'controllerId': controllerId,
    'houseId': houseId,
    'roomId': roomId,
    'status': status,
    'pairedAt': _timestamp(pairedAt),
    'lastSeenAt': _timestamp(lastSeenAt),
  };

  factory NodeRegistryEntry.fromMap(
    Map<String, dynamic> map, {
    String? documentId,
  }) {
    return NodeRegistryEntry(
      nodeId: _requiredString(map, 'nodeId', fallback: documentId),
      controllerId: _optionalString(map['controllerId']),
      houseId: _optionalString(map['houseId']),
      roomId: _optionalString(map['roomId']),
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
    throw FormatException('Node field "$key" must be a non-empty string.');
  }

  static String? _optionalString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
