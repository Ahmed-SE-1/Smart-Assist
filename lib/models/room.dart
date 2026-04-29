class Room {
  final String id;
  final String name;
  final String iconAsset;
  final String esp32NodeId;

  const Room({
    required this.id,
    required this.name,
    required this.iconAsset,
    required this.esp32NodeId,
  });

  Room copyWith({
    String? id,
    String? name,
    String? iconAsset,
    String? esp32NodeId,
  }) {
    return Room(
      id: id ?? this.id,
      name: name ?? this.name,
      iconAsset: iconAsset ?? this.iconAsset,
      esp32NodeId: esp32NodeId ?? this.esp32NodeId,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'iconAsset': iconAsset,
      'esp32NodeId': esp32NodeId,
    };
  }

  factory Room.fromMap(Map<String, dynamic> map) {
    return Room(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      iconAsset: map['iconAsset'] ?? '',
      esp32NodeId: map['esp32NodeId'] ?? '',
    );
  }
}

