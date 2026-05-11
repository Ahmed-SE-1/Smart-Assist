import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/automation_rule.dart';
import '../models/user.dart';
import '../services/hardware_alert_service.dart';
import 'smart_home_provider.dart';
import 'user_provider.dart';

const _uuid = Uuid();

/// Manages all Automation Rules (If-This-Then-That logic) for the Smart Home.
class AutomationNotifier extends Notifier<List<AutomationRule>> {
  Timer? _evaluationTimer;

  // --- UPGRADED: House-Specific Storage Key ---
  String getStorageKey() {
    final user = ref.read(userProvider);
    // User ke houseId ke hisaab se alag key generate hogi
    return 'shared_house_automation_db_${user?.houseId ?? 'default'}';
  }

  @override
  List<AutomationRule> build() {
    // User change hone par rules automatically reload honge
    ref.watch(userProvider);
    Future.microtask(_loadRules);

    _startEvaluation();
    ref.onDispose(() => _evaluationTimer?.cancel());
    return [];
  }

  Future<void> _loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(getStorageKey());
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => AutomationRule.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(getStorageKey(), encoded);
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
      if (rule.property == 'speed') {
        currentValue = targetDevice.fanSpeed.toDouble();
      } else if (rule.property == 'temperature') {
        currentValue = targetDevice.acTemperature.toDouble();
      } else if (rule.property == 'sensor') {
        currentValue = targetDevice.sensorValue;
      } else if (rule.property == 'state') {
        currentValue = targetDevice.isOn ? 1.0 : 0.0;
      }

      bool conditionMet = false;

      if (!targetDevice.isOn && rule.property != 'state') {
        conditionMet = false;
      } else {
        if (rule.operator == '>') {
          conditionMet = currentValue > rule.value;
        } else if (rule.operator == '<') {
          conditionMet = currentValue < rule.value;
        } else if (rule.operator == '==') {
          conditionMet = currentValue == rule.value;
        }
      }

      if (conditionMet) {
        bool shouldAlert = false;

        if (!rule.isCurrentlyViolated) {
          shouldAlert = true;
        } else if (rule.lastTriggered == null ||
            DateTime.now().difference(rule.lastTriggered!).inMinutes >= 1) {
          shouldAlert = true;
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

          updatedRules.add(
            rule.copyWith(
              lastTriggered: DateTime.now(),
              isCurrentlyViolated: true,
            ),
          );
          stateChanged = true;
        } else {
          updatedRules.add(rule);
        }
      } else {
        if (rule.isCurrentlyViolated) {
          updatedRules.add(rule.copyWith(isCurrentlyViolated: false));
          stateChanged = true;
        } else {
          updatedRules.add(rule);
        }
      }
    }

    if (stateChanged) {
      state = updatedRules;
      _saveRules();
    }
  }

  void toggleRule(String ruleId) {
    state = state.map((r) => r.id == ruleId ? r.copyWith(isActive: !r.isActive) : r).toList();
    _saveRules();
  }

  void removeRule(String ruleId) {
    state = state.where((r) => r.id != ruleId).toList();
    _saveRules();
  }

  void removeRulesForDevice(String deviceId) {
    state = state.where((r) => r.targetDeviceId != deviceId).toList();
    _saveRules();
  }

  void addOrUpdateRule({
    String? existingId,
    required String name,
    required String targetDeviceId,
    required String property,
    required String operator,
    required double value,
    required String action,
    required String creatorId,
    required String creatorName,
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
      creatorId: creatorId,
      creatorName: creatorName,
    );

    if (existingId != null) {
      state = state.map((r) => r.id == existingId ? rule : r).toList();
    } else {
      state = [...state, rule];
    }

    _saveRules();
  }
}

// Ye base provider hai jisme sabka data hoga (Background logic ke liye)
final automationProvider = NotifierProvider<AutomationNotifier, List<AutomationRule>>(
  AutomationNotifier.new,
);

// --- ACCESS CONTROL FILTER FOR AUTOMATION RULES ---
// UI ko humesha is provider ko watch karna chahiye
final visibleAutomationProvider = Provider<List<AutomationRule>>((ref) {
  final user = ref.watch(userProvider);
  final allRules = ref.watch(automationProvider);

  if (user == null) return [];

  if (user.role == UserRole.owner) {
    // Agar user Owner hai, usko is specific ghar ke saare rules dikhao
    return allRules;
  } else {
    // Agar user Member hai, toh sirf uske apne create kiye hue rules dikhao
    return allRules.where((rule) => rule.creatorId == user.id).toList();
  }
});