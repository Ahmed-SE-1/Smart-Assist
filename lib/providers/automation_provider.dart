import 'dart:async';
import 'dart:convert'; // NAYA: JSON encoding/decoding ke liye

import 'package:firebase_auth/firebase_auth.dart'; // NAYA: User ID get karne ke liye
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart'; // NAYA: Local storage ke liye
import 'package:uuid/uuid.dart';

import '../models/automation_rule.dart';
import '../services/hardware_alert_service.dart';
import 'smart_home_provider.dart';

const _uuid = Uuid();

class AutomationNotifier extends Notifier<List<AutomationRule>> {
  Timer? _evaluationTimer;

  // NAYA: Har user ke liye unique automation storage key
  String get _storageKey {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';
    return '${uid}_saved_automation_db';
  }

  @override
  List<AutomationRule> build() {
    _loadRules(); // NAYA: App start hotay hi rules load hongay
    _startEvaluation();
    ref.onDispose(() => _evaluationTimer?.cancel());
    return [];
  }

  // === NAYA: DATA LOAD KARNE KA FUNCTION ===
  Future<void> _loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);
    if (data != null) {
      final List decoded = jsonDecode(data);
      state = decoded.map((e) => AutomationRule.fromMap(e)).toList();
    } else {
      state = [];
    }
  }

  // === NAYA: DATA SAVE KARNE KA FUNCTION ===
  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(_storageKey, encoded);
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
      if (!targetDevice.isOn && rule.property != 'state') {
        conditionMet = false;
      } else {
        // Agar device ON hai, ya phir rule hi ON/OFF check karne ka hai, tab limit check karo
        if (rule.operator == '>') conditionMet = currentValue > rule.value;
        else if (rule.operator == '<') conditionMet = currentValue < rule.value;
        else if (rule.operator == '==') conditionMet = currentValue == rule.value;
      }

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
      _saveRules(); // NAYA: Data save hoga jab flag ya time update hoga
    }
  }

  void toggleRule(String ruleId) {
    state = state.map((r) => r.id == ruleId ? r.copyWith(isActive: !r.isActive) : r).toList();
    _saveRules(); // NAYA: Data save hoga
  }

  void removeRule(String ruleId) {
    state = state.where((r) => r.id != ruleId).toList();
    _saveRules(); // NAYA: Data save hoga
  }

  // NAYA: Ye function us waqt call hoga jab koi device delete hogi
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

    _saveRules(); // NAYA: Data save hoga
  }
}

final automationProvider = NotifierProvider<AutomationNotifier, List<AutomationRule>>(AutomationNotifier.new);