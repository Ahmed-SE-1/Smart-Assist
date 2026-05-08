enum DeviceType { light, fan, ac, sensor }

class Device {
  final String id;
  final String name;
  final DeviceType type;
  final String roomId;
  final bool isOn;
  final int fanSpeed;
  final int acTemperature;
  final double sensorValue;
  final String sensorType;

  const Device({
    required this.id,
    required this.name,
    required this.type,
    required this.roomId,
    this.isOn = false,
    this.fanSpeed = 0,
    this.acTemperature = 24,
    this.sensorValue = 0.0,
    this.sensorType = 'temperature',
  });

  Device copyWith({
    String? id,
    String? name,
    DeviceType? type,
    String? roomId,
    bool? isOn,
    int? fanSpeed,
    int? acTemperature,
    double? sensorValue,
    String? sensorType,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      roomId: roomId ?? this.roomId,
      isOn: isOn ?? this.isOn,
      fanSpeed: fanSpeed ?? this.fanSpeed,
      acTemperature: acTemperature ?? this.acTemperature,
      sensorValue: sensorValue ?? this.sensorValue,
      sensorType: sensorType ?? this.sensorType,
    );
  }

  // === NAYA: Data save karne ke liye Map mein convert ===
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name, // enum ko String mein save karna
      'roomId': roomId,
      'isOn': isOn,
      'fanSpeed': fanSpeed,
      'acTemperature': acTemperature,
      'sensorValue': sensorValue,
      'sensorType': sensorType,
    };
  }

  // === NAYA: Data load karne ke liye Map se Object banana ===
  factory Device.fromMap(Map<String, dynamic> map) {
    return Device(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Unknown',
      type: DeviceType.values.firstWhere(
            (e) => e.name == map['type'],
        orElse: () => DeviceType.light, // Default
      ),
      roomId: map['roomId'] ?? '',
      isOn: map['isOn'] ?? false,
      fanSpeed: map['fanSpeed'] ?? 0,
      acTemperature: map['acTemperature'] ?? 24,
      sensorValue: map['sensorValue'] != null ? (map['sensorValue'] as num).toDouble() : 0.0,
      sensorType: map['sensorType'] ?? 'temperature',
    );
  }
}