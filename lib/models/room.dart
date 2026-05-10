class Room {
  final String id;
  final String name;
  final String iconAsset;
  final String esp32NodeId;
  // --- NEW: Creator Details ---
  final String creatorId;
  final String creatorName;

  const Room({
    required this.id,
    required this.name,
    required this.iconAsset,
    required this.esp32NodeId,
    required this.creatorId,
    required this.creatorName,
  });

  Room copyWith({
    String? id,
    String? name,
    String? iconAsset,
    String? esp32NodeId,
    String? creatorId,
    String? creatorName,
  }) {
    return Room(
      id: id ?? this.id,
      name: name ?? this.name,
      iconAsset: iconAsset ?? this.iconAsset,
      esp32NodeId: esp32NodeId ?? this.esp32NodeId,
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
      'creatorId': creatorId,
      'creatorName': creatorName,
    };
  }

  factory Room.fromMap(Map<String, dynamic> map) {
    return Room(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      iconAsset: map['iconAsset'] ?? '',
      esp32NodeId: map['esp32NodeId'] ?? '',
      creatorId: map['creatorId'] ?? '',
      creatorName: map['creatorName'] ?? 'Unknown Member',
    );
  }
}