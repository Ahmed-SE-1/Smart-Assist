enum DeviceType { light, fan, ac, sensor }

/// Logical relay channels understood by the tested ESP32 firmware.
abstract final class RelayChannel {
  static const fan = 1;
  static const light = 2;
}

/// Limits used by the manual device sliders and gesture adjustments.
abstract final class DeviceControlLimits {
  static const fanOffSpeed = 0;
  static const minRunningFanSpeed = 1;
  static const maxFanSpeed = 5;
  static const fanSpeedStep = 1;
  static const minAcTemperature = 16;
  static const maxAcTemperature = 30;
  static const acTemperatureStep = 1;
}

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

  /// Logical relay channel. Fan is 1 and light is 2. AC and sensors stay null.
  final int? channel;

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
    this.channel,
  });

  static bool isRelayType(DeviceType type) =>
      type == DeviceType.fan || type == DeviceType.light;

  /// The only channel the tested firmware accepts for [type], or null.
  static int? channelForType(DeviceType type) {
    switch (type) {
      case DeviceType.fan:
        return RelayChannel.fan;
      case DeviceType.light:
        return RelayChannel.light;
      case DeviceType.ac:
      case DeviceType.sensor:
        return null;
    }
  }

  static bool isChannelCompatible(DeviceType type, int? channel) {
    if (!isRelayType(type)) return channel == null;
    return channel == channelForType(type);
  }

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
    int? channel,
    bool applyChannel = false,
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
      channel: applyChannel ? channel : this.channel,
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
      'channel': channel,
    };
  }

  // === NAYA: Data load karne ke liye Map se Object banana ===
  factory Device.fromMap(Map<String, dynamic> map) {
    final type = DeviceType.values.firstWhere(
      (e) => e.name == map['type'],
      orElse: () => DeviceType.light,
    );
    return Device(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Unknown',
      type: type,
      roomId: map['roomId'] ?? '',
      isOn: map['isOn'] ?? false,
      fanSpeed: map['fanSpeed'] ?? 0,
      acTemperature: map['acTemperature'] ?? 24,
      sensorValue:
          map['sensorValue'] != null
              ? (map['sensorValue'] as num).toDouble()
              : 0.0,
      sensorType: map['sensorType'] ?? 'temperature',
      channel: _channelFromMap(type, map['channel']),
    );
  }

  /// Missing channels for a fan or light use the single firmware channel for
  /// that type. A stored number is kept so an incompatible value can be
  /// rejected later instead of being rewritten during load. AC and sensors
  /// never receive a relay channel.
  static int? _channelFromMap(DeviceType type, Object? raw) {
    if (!isRelayType(type)) return null;
    if (raw is num) return raw.toInt();
    return channelForType(type);
  }
}
