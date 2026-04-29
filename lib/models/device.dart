class Device {
  final String id;
  final String name;
  final DeviceType type;
  final bool isOn;
  final String roomId;
  // Extra fields for device-specific behavior
  final int fanSpeed;       // 0–5 for fans
  final int acTemperature;  // 16–30 for AC
  final double sensorValue; // temp/motion for sensors
  final String sensorType;  // 'temperature' or 'motion'
  
  const Device({
    required this.id,
    required this.name,
    required this.type,
    this.isOn = false,
    required this.roomId,
    this.fanSpeed = 0,
    this.acTemperature = 24,
    this.sensorValue = 0.0,
    this.sensorType = 'temperature',
  });

  Device copyWith({
    String? id,
    String? name,
    DeviceType? type,
    bool? isOn,
    String? roomId,
    int? fanSpeed,
    int? acTemperature,
    double? sensorValue,
    String? sensorType,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      isOn: isOn ?? this.isOn,
      roomId: roomId ?? this.roomId,
      fanSpeed: fanSpeed ?? this.fanSpeed,
      acTemperature: acTemperature ?? this.acTemperature,
      sensorValue: sensorValue ?? this.sensorValue,
      sensorType: sensorType ?? this.sensorType,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'isOn': isOn,
      'roomId': roomId,
      'fanSpeed': fanSpeed,
      'acTemperature': acTemperature,
      'sensorValue': sensorValue,
      'sensorType': sensorType,
    };
  }

  factory Device.fromMap(Map<String, dynamic> map) {
    return Device(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      type: DeviceType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => DeviceType.light,
      ),
      isOn: map['isOn'] ?? false,
      roomId: map['roomId'] ?? '',
      fanSpeed: map['fanSpeed'] ?? 0,
      acTemperature: map['acTemperature'] ?? 24,
      sensorValue: map['sensorValue'] ?? 0.0,
      sensorType: map['sensorType'] ?? 'temperature',
    );
  }
}

enum DeviceType { light, fan, ac, sensor }
