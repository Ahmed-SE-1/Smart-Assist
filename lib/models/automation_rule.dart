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
  final bool isCurrentlyViolated; // NAYA: Check karne ke liye ke rule abhi break ho raha hai ya nahi

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
    this.isCurrentlyViolated = false, // Default false hoga
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
}