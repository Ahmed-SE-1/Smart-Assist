import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore registry entry for a House.
///
/// Existing SmartAssist House IDs are owner Firebase Auth UIDs. This registry
/// keeps those IDs stable so MQTT topics and local room storage remain valid.
class House {
  const House({
    required this.houseId,
    required this.ownerUid,
    required this.name,
    this.mainControllerId,
    this.createdAt,
    this.updatedAt,
  });

  final String houseId;
  final String ownerUid;
  final String name;
  final String? mainControllerId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toMap() => {
    'houseId': houseId,
    'ownerUid': ownerUid,
    'name': name,
    'mainControllerId': mainControllerId,
    'createdAt': _timestamp(createdAt),
    'updatedAt': _timestamp(updatedAt),
  };

  factory House.fromMap(Map<String, dynamic> map, {String? documentId}) {
    return House(
      houseId: _requiredString(map, 'houseId', fallback: documentId),
      ownerUid: _requiredString(map, 'ownerUid'),
      name: _requiredString(map, 'name'),
      mainControllerId: _optionalString(map['mainControllerId']),
      createdAt: _readDateTime(map['createdAt']),
      updatedAt: _readDateTime(map['updatedAt']),
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
    throw FormatException('House field "$key" must be a non-empty string.');
  }

  static String? _optionalString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
