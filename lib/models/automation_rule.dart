class AutomationRule {
  final String id;
  final String name;
  final String condition;
  final String action;
  final String targetDeviceId;
  final bool isActive;

  const AutomationRule({
    required this.id,
    required this.name,
    required this.condition,
    required this.action,
    required this.targetDeviceId,
    this.isActive = true,
  });

  AutomationRule copyWith({
    String? id,
    String? name,
    String? condition,
    String? action,
    String? targetDeviceId,
    bool? isActive,
  }) {
    return AutomationRule(
      id: id ?? this.id,
      name: name ?? this.name,
      condition: condition ?? this.condition,
      action: action ?? this.action,
      targetDeviceId: targetDeviceId ?? this.targetDeviceId,
      isActive: isActive ?? this.isActive,
    );
  }
}
