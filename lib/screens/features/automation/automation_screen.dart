import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/automation_rule.dart';
import '../../../providers/automation_provider.dart';
import '../../../providers/smart_home_provider.dart';

/// The screen where users can view, create, edit, and toggle Smart Home Automation Rules.
/// Uses a [ConsumerWidget] to listen to `automationProvider` and rebuild automatically.
class AutomationScreen extends ConsumerWidget {
  const AutomationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the automation rules array
    final rules = ref.watch(automationProvider);
    // Watch the devices array to map device IDs to readable names
    final devices = ref.watch(devicesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('Automation Rules'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body:
          rules.isEmpty
              ? const Center(child: Text('No automation rules set yet.'))
              : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: rules.length,
                itemBuilder: (context, index) {
                  final rule = rules[index];
                  final deviceName =
                      devices
                          .firstWhere(
                            (d) => d.id == rule.targetDeviceId,
                            orElse: () => devices.first,
                          )
                          .name;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rule.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'If: $deviceName ${rule.property} ${rule.operator} ${rule.value}',
                              ),
                              Text(
                                'Then: ${rule.action.replaceAll('_', ' ').toUpperCase()}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Actions: Edit, Delete, Switch
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.edit,
                                color: Colors.blue,
                                size: 20,
                              ),
                              onPressed:
                                  () => _showRuleDialog(
                                    context,
                                    ref,
                                    existingRule: rule,
                                  ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.red,
                                size: 20,
                              ),
                              onPressed:
                                  () => ref
                                      .read(automationProvider.notifier)
                                      .removeRule(rule.id),
                            ),
                            Switch(
                              value: rule.isActive,
                              onChanged:
                                  (val) => ref
                                      .read(automationProvider.notifier)
                                      .toggleRule(rule.id),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRuleDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New Rule'),
      ),
    );
  }

  /// Displays a comprehensive dialog for creating or editing an Automation Rule.
  /// Uses a [StatefulBuilder] to update the dialog's local UI state (dropdowns, chips) instantly.
  void _showRuleDialog(
    BuildContext context,
    WidgetRef ref, {
    AutomationRule? existingRule,
  }) {
    final isEditing = existingRule != null;
    final nameController = TextEditingController(
      text: existingRule?.name ?? '',
    );
    final valueController = TextEditingController(
      text: existingRule?.value.toString() ?? '',
    );

    final devices = ref.read(devicesProvider);
    final allRooms = ref.read(roomsProvider);
    final roomIds = devices.map((d) => d.roomId).toSet().toList();

    String? selectedRoom;
    String? selectedDeviceId = existingRule?.targetDeviceId;
    String selectedProperty = existingRule?.property ?? 'state';
    String selectedOperator = existingRule?.operator ?? '>';
    String selectedAction = existingRule?.action ?? 'alert';

    if (isEditing && selectedDeviceId != null) {
      try {
        selectedRoom = devices.firstWhere((d) => d.id == selectedDeviceId).roomId;
      } catch (_) {}
    }

    final properties = [
      {'value': 'speed', 'label': 'Speed', 'icon': Icons.speed},
      {'value': 'temperature', 'label': 'Temp', 'icon': Icons.thermostat},
      {'value': 'sensor', 'label': 'Sensor', 'icon': Icons.sensors},
      {'value': 'state', 'label': 'State (ON/OFF)', 'icon': Icons.power_settings_new},
    ];

    final operators = [
      {'value': '>', 'label': 'Greater (>)'},
      {'value': '<', 'label': 'Less (<)'},
      {'value': '==', 'label': 'Equal (==)'},
    ];

    final actions = [
      {'value': 'alert', 'label': 'Alert', 'icon': Icons.notifications_active},
      {'value': 'turn_on', 'label': 'Turn ON', 'icon': Icons.lightbulb},
      {'value': 'turn_off', 'label': 'Turn OFF', 'icon': Icons.lightbulb_outline},
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final filteredDevices = selectedRoom == null
              ? devices
              : devices.where((d) => d.roomId == selectedRoom).toList();

          if (selectedDeviceId != null && !filteredDevices.any((d) => d.id == selectedDeviceId)) {
            selectedDeviceId = null;
          }

          final inputDecoration = InputDecoration(
            filled: true,
            fillColor: Colors.grey.shade100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          );

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Text(isEditing ? 'Edit Rule' : 'Create Rule', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: inputDecoration.copyWith(labelText: 'Rule Name', hintText: 'e.g. High Temp Alert'),
                    ),
                    const SizedBox(height: 24),

                    const Text('Filter by Room', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: selectedRoom,
                      decoration: inputDecoration,
                      hint: const Text('Select a Room (Optional)'),
                      items: roomIds.map((id) {
                        String roomName = 'Unknown Room';
                        try { roomName = allRooms.firstWhere((r) => r.id == id).name; } catch (_) {}
                        return DropdownMenuItem(value: id, child: Text(roomName));
                      }).toList(),
                      onChanged: (v) => setDialogState(() => selectedRoom = v),
                    ),
                    const SizedBox(height: 16),

                    const Text('Target Device *', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: selectedDeviceId,
                      decoration: inputDecoration,
                      hint: const Text('Select a Device'),
                      items: filteredDevices.map((d) => DropdownMenuItem(value: d.id, child: Text('${d.name} (${d.type.name})'))).toList(),
                      onChanged: (v) => setDialogState(() => selectedDeviceId = v),
                    ),
                    const SizedBox(height: 24),

                    const Text('Condition Property', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: properties.map((p) {
                        final isSelected = selectedProperty == p['value'];
                        return ChoiceChip(
                          label: Text(p['label'] as String),
                          avatar: Icon(p['icon'] as IconData, size: 18, color: isSelected ? Colors.white : Colors.grey.shade700),
                          selected: isSelected,
                          selectedColor: Theme.of(context).colorScheme.primary,
                          labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.grey.shade800),
                          onSelected: (bool selected) {
                            if (selected) setDialogState(() => selectedProperty = p['value'] as String);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),

                    const Text('Condition Logic', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            value: selectedOperator,
                            decoration: inputDecoration,
                            items: operators.map((o) => DropdownMenuItem(value: o['value'] as String, child: Text(o['label'] as String))).toList(),
                            onChanged: (v) => setDialogState(() => selectedOperator = v!),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: valueController,
                            keyboardType: TextInputType.number,
                            decoration: inputDecoration.copyWith(labelText: 'Value', hintText: 'e.g. 30'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    const Text('Action to Perform', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: actions.map((a) {
                        final isSelected = selectedAction == a['value'];
                        return ChoiceChip(
                          label: Text(a['label'] as String),
                          avatar: Icon(a['icon'] as IconData, size: 18, color: isSelected ? Colors.white : Colors.grey.shade700),
                          selected: isSelected,
                          selectedColor: Theme.of(context).colorScheme.secondary,
                          labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.grey.shade800),
                          onSelected: (bool selected) {
                            if (selected) setDialogState(() => selectedAction = a['value'] as String);
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.all(24),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: Colors.grey.shade600)),
              ),
              ElevatedButton(
                onPressed: () {
                  if (selectedDeviceId == null || valueController.text.isEmpty) return;
                  ref.read(automationProvider.notifier).addOrUpdateRule(
                    existingId: isEditing ? existingRule.id : null,
                    name: nameController.text.isNotEmpty ? nameController.text : 'New Rule',
                    targetDeviceId: selectedDeviceId!,
                    property: selectedProperty,
                    operator: selectedOperator,
                    value: double.parse(valueController.text),
                    action: selectedAction,
                  );
                  Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(isEditing ? 'Update Rule' : 'Save Rule'),
              ),
            ],
          );
        },
      ),
    );
  }
}
