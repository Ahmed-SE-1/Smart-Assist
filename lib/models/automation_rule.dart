class AutomationRule {
  final String id;
  final String name;
  final String targetDeviceId;
  final String property;
  final String operator;
  final double value;
  final String action;
  final bool isActive;
  final DateTime? lastTriggered;
  final bool isCurrentlyViolated;

  const AutomationRule({
    required this.id,
    required this.name,
    required this.targetDeviceId,
    required this.property,
    required this.operator,
    required this.value,
    required this.action,
    this.isActive = true,
    this.lastTriggered,
    this.isCurrentlyViolated = false,
  });

  AutomationRule copyWith({
    String? id,
    String? name,
    String? targetDeviceId,
    String? property,
    String? operator,
    double? value,
    String? action,
    bool? isActive,
    DateTime? lastTriggered,
    bool? isCurrentlyViolated,
  }) {
    return AutomationRule(
      id: id ?? this.id,
      name: name ?? this.name,
      targetDeviceId: targetDeviceId ?? this.targetDeviceId,
      property: property ?? this.property,
      operator: operator ?? this.operator,
      value: value ?? this.value,
      action: action ?? this.action,
      isActive: isActive ?? this.isActive,
      lastTriggered: lastTriggered ?? this.lastTriggered,
      isCurrentlyViolated: isCurrentlyViolated ?? this.isCurrentlyViolated,
    );
  }

  // --- NAYA: Model ko JSON ke liye Map mein convert karna ---
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'targetDeviceId': targetDeviceId,
      'property': property,
      'operator': operator,
      'value': value,
      'action': action,
      'isActive': isActive,
      'lastTriggered': lastTriggered?.toIso8601String(),
      'isCurrentlyViolated': isCurrentlyViolated,
    };
  }

  // --- NAYA: JSON Map ko wapis Model mein convert karna ---
  factory AutomationRule.fromMap(Map<String, dynamic> map) {
    return AutomationRule(
      id: map['id'],
      name: map['name'],
      targetDeviceId: map['targetDeviceId'],
      property: map['property'],
      operator: map['operator'],
      // value ko double mein securely parse karna
      value: map['value'] is int ? (map['value'] as int).toDouble() : map['value'] as double,
      action: map['action'],
      isActive: map['isActive'] ?? true,
      lastTriggered: map['lastTriggered'] != null ? DateTime.parse(map['lastTriggered']) : null,
      isCurrentlyViolated: map['isCurrentlyViolated'] ?? false,
    );
  }
}