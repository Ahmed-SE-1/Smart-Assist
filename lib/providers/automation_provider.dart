import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/automation_rule.dart';
import '../models/device.dart';
import 'smart_home_provider.dart';

const _uuid = Uuid();

class AutomationNotifier extends Notifier<List<AutomationRule>> {
  Timer? _evaluationTimer;

  @override
  List<AutomationRule> build() {
    // Get initial device IDs for default rules
    final devices = ref.read(devicesProvider);
    
    String acId = 'd4';
    String lightId = 'd5';
    
    // Find sensor-related devices for default rules
    try {
      final ac = devices.firstWhere((d) => d.type == DeviceType.ac);
      acId = ac.id;
    } catch (_) {}
    try {
      final kitchenLight = devices.firstWhere((d) => d.name.toLowerCase().contains('kitchen') && d.type == DeviceType.light);
      lightId = kitchenLight.id;
    } catch (_) {}

    // Start background evaluation
    _startEvaluation();

    ref.onDispose(() {
      _evaluationTimer?.cancel();
    });

    return [
      AutomationRule(
        id: 'rule1',
        name: 'Heat Protection',
        condition: 'temperature > 30',
        action: 'Turn ON AC',
        targetDeviceId: acId,
        isActive: true,
      ),
      AutomationRule(
        id: 'rule2',
        name: 'Motion Light',
        condition: 'motion detected',
        action: 'Turn ON Kitchen Light',
        targetDeviceId: lightId,
        isActive: true,
      ),
    ];
  }

  void _startEvaluation() {
    _evaluationTimer?.cancel();
    _evaluationTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _evaluateRules();
    });
  }

  void _evaluateRules() {
    final rules = state;
    final devices = ref.read(devicesProvider);
    final devicesNotifier = ref.read(devicesProvider.notifier);

    for (final rule in rules) {
      if (!rule.isActive) continue;

      final targetDevice = devicesNotifier.getById(rule.targetDeviceId);
      if (targetDevice == null) continue;

      bool conditionMet = false;

      // Parse condition
      if (rule.condition.startsWith('temperature >')) {
        final threshold = double.tryParse(rule.condition.replaceAll('temperature >', '').trim()) ?? 30;
        // Find any temperature sensor
        try {
          final sensor = devices.firstWhere(
            (d) => d.type == DeviceType.sensor && d.sensorType == 'temperature',
          );
          conditionMet = sensor.sensorValue > threshold;
        } catch (_) {}
      } else if (rule.condition == 'motion detected') {
        // Find any motion sensor
        try {
          final sensor = devices.firstWhere(
            (d) => d.type == DeviceType.sensor && d.sensorType == 'motion',
          );
          conditionMet = sensor.sensorValue > 0.5;
        } catch (_) {}
      } else if (rule.condition.startsWith('temperature <')) {
        final threshold = double.tryParse(rule.condition.replaceAll('temperature <', '').trim()) ?? 20;
        try {
          final sensor = devices.firstWhere(
            (d) => d.type == DeviceType.sensor && d.sensorType == 'temperature',
          );
          conditionMet = sensor.sensorValue < threshold;
        } catch (_) {}
      }

      // Execute action if condition met and device is not already in desired state
      if (conditionMet) {
        final actionLower = rule.action.toLowerCase();
        if (actionLower.contains('turn on') && !targetDevice.isOn) {
          devicesNotifier.turnOn(rule.targetDeviceId, method: 'automation');
        } else if (actionLower.contains('turn off') && targetDevice.isOn) {
          devicesNotifier.turnOff(rule.targetDeviceId, method: 'automation');
        }
      }
    }
  }

  void toggleRule(String ruleId) {
    state = state.map((r) {
      if (r.id == ruleId) return r.copyWith(isActive: !r.isActive);
      return r;
    }).toList();
  }

  /// Add a new automation rule.
  String? addRule({
    required String name,
    required String condition,
    required String action,
    required String targetDeviceId,
  }) {
    if (name.trim().isEmpty) return 'Rule name cannot be empty';
    if (condition.trim().isEmpty) return 'Condition cannot be empty';
    if (action.trim().isEmpty) return 'Action cannot be empty';

    final rule = AutomationRule(
      id: _uuid.v4(),
      name: name.trim(),
      condition: condition.trim(),
      action: action.trim(),
      targetDeviceId: targetDeviceId,
      isActive: true,
    );

    state = [...state, rule];
    return null;
  }

  void removeRule(String ruleId) {
    state = state.where((r) => r.id != ruleId).toList();
  }
}

final automationProvider = NotifierProvider<AutomationNotifier, List<AutomationRule>>(AutomationNotifier.new);
