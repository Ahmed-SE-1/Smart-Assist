import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/automation_rule.dart';
import '../services/hardware_alert_service.dart';
import 'smart_home_provider.dart';

const _uuid = Uuid();

class AutomationNotifier extends Notifier<List<AutomationRule>> {
  Timer? _evaluationTimer;

  @override
  List<AutomationRule> build() {
    _startEvaluation();
    ref.onDispose(() => _evaluationTimer?.cancel());
    return []; // Yahan aap chahain toh default rules rakh saktay hain
  }

  void _startEvaluation() {
    _evaluationTimer?.cancel();
    _evaluationTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _evaluateRules();
    });
  }

  void _evaluateRules() {
    final rules = state;
    final devicesNotifier = ref.read(devicesProvider.notifier);

    bool stateChanged = false;
    List<AutomationRule> updatedRules = [];

    for (var rule in rules) {
      if (!rule.isActive) {
        updatedRules.add(rule);
        continue;
      }

      final targetDevice = devicesNotifier.getById(rule.targetDeviceId);
      if (targetDevice == null) {
        updatedRules.add(rule);
        continue;
      }

      double currentValue = 0.0;
      if (rule.property == 'speed') currentValue = targetDevice.fanSpeed.toDouble();
      else if (rule.property == 'temperature') currentValue = targetDevice.acTemperature.toDouble();
      else if (rule.property == 'sensor') currentValue = targetDevice.sensorValue;
      else if (rule.property == 'state') currentValue = targetDevice.isOn ? 1.0 : 0.0;

      bool conditionMet = false;
      if (rule.operator == '>') conditionMet = currentValue > rule.value;
      else if (rule.operator == '<') conditionMet = currentValue < rule.value;
      else if (rule.operator == '==') conditionMet = currentValue == rule.value;

      if (conditionMet) {
        bool shouldAlert = false;

        // LOGIC: Pehli bar rule toota, YA phir 1 min guzar gaya
        if (!rule.isCurrentlyViolated) {
          shouldAlert = true; // Rule just abhi toota hai (Immediate Alert)
        } else if (rule.lastTriggered == null || DateTime.now().difference(rule.lastTriggered!).inMinutes >= 1) {
          shouldAlert = true; // 1 minute guzar gaya magar user ne follow nahi kiya
        }

        if (shouldAlert) {
          if (rule.action == 'alert') {
            HardwareAlertService.trigger();
            ref.read(activityLogProvider.notifier).addLog(
              deviceId: targetDevice.id,
              deviceName: targetDevice.name,
              roomId: targetDevice.roomId,
              action: 'RULE DISOBEYED: ${rule.name}',
              method: 'automation_alert',
            );
          } else if (rule.action == 'turn_on' && !targetDevice.isOn) {
            devicesNotifier.turnOn(targetDevice.id, method: 'automation');
          } else if (rule.action == 'turn_off' && targetDevice.isOn) {
            devicesNotifier.turnOff(targetDevice.id, method: 'automation');
          }

          updatedRules.add(rule.copyWith(
            lastTriggered: DateTime.now(),
            isCurrentlyViolated: true, // Flag ON kar diya ke rule abhi toota hua hai
          ));
          stateChanged = true;
        } else {
          updatedRules.add(rule);
        }
      } else {
        // LOGIC: User ne rule follow kar liya (Condition false ho gayi)
        if (rule.isCurrentlyViolated) {
          updatedRules.add(rule.copyWith(isCurrentlyViolated: false)); // Flag reset
          stateChanged = true;
        } else {
          updatedRules.add(rule);
        }
      }
    }

    if (stateChanged) {
      state = updatedRules;
    }
  }

  void toggleRule(String ruleId) {
    state = state.map((r) => r.id == ruleId ? r.copyWith(isActive: !r.isActive) : r).toList();
  }

  void removeRule(String ruleId) {
    state = state.where((r) => r.id != ruleId).toList();
  }

  void addOrUpdateRule({
    String? existingId,
    required String name,
    required String targetDeviceId,
    required String property,
    required String operator,
    required double value,
    required String action,
  }) {
    final rule = AutomationRule(
      id: existingId ?? _uuid.v4(),
      name: name.trim(),
      targetDeviceId: targetDeviceId,
      property: property,
      operator: operator,
      value: value,
      action: action,
      isActive: true,
    );

    if (existingId != null) {
      // Update
      state = state.map((r) => r.id == existingId ? rule : r).toList();
    } else {
      // Add New
      state = [...state, rule];
    }
  }
}

final automationProvider = NotifierProvider<AutomationNotifier, List<AutomationRule>>(AutomationNotifier.new);