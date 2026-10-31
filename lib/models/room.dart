class Room {
  /// Firmware MQTT node for the first tested room ESP32.
  static const room1NodeId = 'ROOM1_NODE';

  /// Firmware MQTT node for the second tested room ESP32.
  static const room2NodeId = 'ROOM2_NODE';

  static const supportedMqttNodeIds = <String>[room1NodeId, room2NodeId];

  final String id;
  final String name;
  final String iconAsset;
  final String esp32NodeId;

  /// Firmware topic node, such as [room1NodeId]. Null means this room is not
  /// mapped and its devices must not be published to a guessed node.
  final String? mqttNodeId;

  // --- NEW: Creator Details ---
  final String creatorId;
  final String creatorName;

  const Room({
    required this.id,
    required this.name,
    required this.iconAsset,
    required this.esp32NodeId,
    this.mqttNodeId,
    required this.creatorId,
    required this.creatorName,
  });

  static bool isSupportedMqttNodeId(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return false;
    return supportedMqttNodeIds.contains(trimmed);
  }

  /// Highest `NODE_###` suffix already stored. Existing ids are left unchanged.
  static int highestEsp32Counter(Iterable<Room> rooms) {
    final pattern = RegExp(r'^NODE_(\d+)$');
    var highest = 0;
    for (final room in rooms) {
      final match = pattern.firstMatch(room.esp32NodeId.trim());
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!) ?? 0;
      if (value > highest) highest = value;
    }
    return highest;
  }

  Room copyWith({
    String? id,
    String? name,
    String? iconAsset,
    String? esp32NodeId,
    Object? mqttNodeId = _keep,
    String? creatorId,
    String? creatorName,
  }) {
    return Room(
      id: id ?? this.id,
      name: name ?? this.name,
      iconAsset: iconAsset ?? this.iconAsset,
      esp32NodeId: esp32NodeId ?? this.esp32NodeId,
      mqttNodeId:
          identical(mqttNodeId, _keep)
              ? this.mqttNodeId
              : mqttNodeId as String?,
      creatorId: creatorId ?? this.creatorId,
      creatorName: creatorName ?? this.creatorName,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'iconAsset': iconAsset,
      'esp32NodeId': esp32NodeId,
      'mqttNodeId': mqttNodeId,
      'creatorId': creatorId,
      'creatorName': creatorName,
    };
  }

  factory Room.fromMap(Map<String, dynamic> map) {
    final rawNode = map['mqttNodeId'];
    final node =
        rawNode is String && isSupportedMqttNodeId(rawNode)
            ? rawNode.trim()
            : null;
    return Room(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      iconAsset: map['iconAsset'] ?? '',
      esp32NodeId: map['esp32NodeId'] ?? '',
      mqttNodeId: node,
      creatorId: map['creatorId'] ?? '',
      creatorName: map['creatorName'] ?? 'Unknown Member',
    );
  }
}

const Object _keep = Object();
