import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/automation_rule.dart';
import '../services/hardware_alert_service.dart';
import 'smart_home_provider.dart';

const _uuid = Uuid();

/// Manages all Automation Rules (If-This-Then-That logic) for the Smart Home.
/// It continuously evaluates rules against current sensor data and triggers actions.
class AutomationNotifier extends Notifier<List<AutomationRule>> {
  Timer? _evaluationTimer;

  /// Generates a unique local storage key based on the currently logged-in user.
  /// This ensures that different users on the same device don't mix their automation rules.
  String get _storageKey {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? 'guest';
    return '${uid}_saved_automation_db';
  }

  @override
  List<AutomationRule> build() {
    // 1. Load rules from disk immediately upon provider creation
    _loadRules();

    // 2. Start the background loop that checks conditions every few seconds
    _startEvaluation();

    // 3. Clean up the timer when this provider is destroyed to prevent memory leaks
    ref.onDispose(() => _evaluationTimer?.cancel());

    return [];
  }

  /// Fetches saved JSON rules from SharedPreferences and parses them into Dart objects.
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

  /// Converts the current list of AutomationRules into JSON and saves it to SharedPreferences.
  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  /// Starts a looping Timer that calls `_evaluateRules()` every 4 seconds.
  /// This simulates a backend server continuously monitoring sensor limits.
  void _startEvaluation() {
    _evaluationTimer?.cancel(); // Cancel any existing timer first
    _evaluationTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _evaluateRules();
    });
  }

  /// The Core Logic Engine: Loops through all rules, checks them against device states,
  /// and triggers the appropriate actions (Alerts, Turn ON, Turn OFF).
  void _evaluateRules() {
    final rules = state;
    final devicesNotifier = ref.read(
      devicesProvider.notifier,
    ); // Access live device states

    bool stateChanged = false; // Flag to check if we need to update UI
    List<AutomationRule> updatedRules = [];

    // Loop through every single rule the user has created
    for (var rule in rules) {
      // Ignore rules that the user has manually paused
      if (!rule.isActive) {
        updatedRules.add(rule);
        continue;
      }

      // Find the physical device this rule is attached to
      final targetDevice = devicesNotifier.getById(rule.targetDeviceId);
      if (targetDevice == null) {
        updatedRules.add(rule); // Device might be deleted, just skip
        continue;
      }

      // 1. Extract the current live value of the property we are monitoring
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

      // If the device is OFF, we usually shouldn't trigger sensor-based rules for it,
      // UNLESS the rule is specifically monitoring the 'state' (ON/OFF).
      if (!targetDevice.isOn && rule.property != 'state') {
        conditionMet = false;
      } else {
        // Evaluate the mathematical operator chosen by the user
        if (rule.operator == '>') {
          conditionMet = currentValue > rule.value;
        } else if (rule.operator == '<') {
          conditionMet = currentValue < rule.value;
        } else if (rule.operator == '==') {
          conditionMet = currentValue == rule.value;
        }
      }

      // 2. If the condition is met (e.g., Temp > 30)
      if (conditionMet) {
        bool shouldAlert = false;

        // Debouncing Logic: We don't want to spam the user every 4 seconds.
        // We alert immediately the FIRST time it violates, and then only once every 1 minute.
        if (!rule.isCurrentlyViolated) {
          shouldAlert = true; // Rule just broke right now
        } else if (rule.lastTriggered == null ||
            DateTime.now().difference(rule.lastTriggered!).inMinutes >= 1) {
          shouldAlert =
              true; // It's been broken for 1+ minute, remind them again
        }

        if (shouldAlert) {
          // Execute the chosen action
          if (rule.action == 'alert') {
            HardwareAlertService.trigger(); // Flash screen / vibrate
            // Log it in the Activity History
            ref
                .read(activityLogProvider.notifier)
                .addLog(
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

          // Mark this rule as currently violated and update timestamp
          updatedRules.add(
            rule.copyWith(
              lastTriggered: DateTime.now(),
              isCurrentlyViolated: true,
            ),
          );
          stateChanged = true;
        } else {
          updatedRules.add(
            rule,
          ); // Condition met, but we are waiting for the 1-minute cooldown
        }
      } else {
        // 3. If the condition is NOT met (e.g., Temp is back to normal)
        if (rule.isCurrentlyViolated) {
          // The rule is fixed! Reset the violation flag
          updatedRules.add(rule.copyWith(isCurrentlyViolated: false));
          stateChanged = true;
        } else {
          updatedRules.add(rule);
        }
      }
    }

    // Only redraw the UI and save to disk if something actually changed
    if (stateChanged) {
      state = updatedRules;
      _saveRules();
    }
  }

  /// Pauses or unpauses a specific automation rule.
  void toggleRule(String ruleId) {
    state =
        state
            .map((r) => r.id == ruleId ? r.copyWith(isActive: !r.isActive) : r)
            .toList();
    _saveRules();
  }

  /// Completely deletes an automation rule.
  void removeRule(String ruleId) {
    state = state.where((r) => r.id != ruleId).toList();
    _saveRules();
  }

  /// Automatically deletes rules tied to a device when that device is deleted.
  /// (Called directly by DevicesNotifier in smart_home_provider.dart)
  void removeRulesForDevice(String deviceId) {
    state = state.where((r) => r.targetDeviceId != deviceId).toList();
    _saveRules();
  }

  /// Creates a new rule or updates an existing one.
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
      id: existingId ?? _uuid.v4(), // Generate new ID if not updating
      name: name.trim(),
      targetDeviceId: targetDeviceId,
      property: property,
      operator: operator,
      value: value,
      action: action,
      isActive: true, // Rules are active by default
    );

    if (existingId != null) {
      // Update existing
      state = state.map((r) => r.id == existingId ? rule : r).toList();
    } else {
      // Add New
      state = [...state, rule];
    }

    _saveRules();
  }
}

/// Global provider for accessing the Automation state
final automationProvider =
    NotifierProvider<AutomationNotifier, List<AutomationRule>>(
      AutomationNotifier.new,
    );
