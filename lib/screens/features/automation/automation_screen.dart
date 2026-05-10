import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/automation_rule.dart';
import '../../../providers/automation_provider.dart';
import '../../../providers/smart_home_provider.dart';
import '../../../providers/user_provider.dart';

/// The screen where users can view, create, edit, and toggle Smart Home Automation Rules.
class AutomationScreen extends ConsumerWidget {
  const AutomationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // --- UPDATED: Naya filter wala provider use kiya ---
    final rules = ref.watch(visibleAutomationProvider);

    // Yahan saari devices isliye rakhi hain taake list mein naam sahi se show ho
    final devices = ref.watch(devicesProvider);
    final currentUser = ref.watch(userProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('Automation Rules', style: TextStyle(color: Color(0xFF2D3436), fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF2D3436)),
      ),
      body: rules.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('No automation rules set yet.', style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: rules.length,
        itemBuilder: (context, index) {
          final rule = rules[index];
          final deviceName = devices.firstWhere(
                (d) => d.id == rule.targetDeviceId,
            orElse: () => devices.first,
          ).name;

          final canEdit = (currentUser?.role.name == 'owner' || currentUser?.id == rule.creatorId);

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 4))
                ]
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rule.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text('If: $deviceName ${rule.property} ${rule.operator} ${rule.value}', style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(
                        'Then: ${rule.action.replaceAll('_', ' ').toUpperCase()}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // --- CREATOR BADGE ---
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person, size: 12, color: Colors.blue.shade700),
                            const SizedBox(width: 4),
                            Text(
                              'By: ${rule.creatorName}',
                              style: TextStyle(fontSize: 10, color: Colors.blue.shade700, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Actions: Edit, Delete, Switch
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canEdit) ...[
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, color: Colors.blue, size: 20),
                        onPressed: () => _showRuleDialog(context, ref, existingRule: rule),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                        onPressed: () => ref.read(automationProvider.notifier).removeRule(rule.id), // Action hamesha base provider par hogi
                      ),
                    ],
                    Switch(
                      value: rule.isActive,
                      activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: (val) {
                        if(canEdit) ref.read(automationProvider.notifier).toggleRule(rule.id);
                      },
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
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
      ),
    );
  }

  void _showRuleDialog(BuildContext context, WidgetRef ref, {AutomationRule? existingRule}) {
    final isEditing = existingRule != null;
    final nameController = TextEditingController(text: existingRule?.name ?? '');
    final valueController = TextEditingController(text: existingRule?.value.toString() ?? '');

    // --- UPDATED: Sirf wahi rooms nikalo jo is user ko allowed hain ---
    final allRooms = ref.read(visibleRoomsProvider);
    final allowedRoomIds = allRooms.map((r) => r.id).toSet();

    // --- UPDATED: Sirf allowed rooms ki devices show karo ---
    final allDevices = ref.read(devicesProvider);
    final devices = allDevices.where((d) => allowedRoomIds.contains(d.roomId)).toList();

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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
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
                        // allRooms already filtered hai upar
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

                  final currentUser = ref.read(userProvider);

                  // Base provider par hi add hoga (notifier ko use karna lazmi hota hai updates k liye)
                  ref.read(automationProvider.notifier).addOrUpdateRule(
                    existingId: isEditing ? existingRule.id : null,
                    name: nameController.text.isNotEmpty ? nameController.text : 'New Rule',
                    targetDeviceId: selectedDeviceId!,
                    property: selectedProperty,
                    operator: selectedOperator,
                    value: double.parse(valueController.text),
                    action: selectedAction,
                    creatorId: currentUser?.id ?? '',
                    creatorName: currentUser?.name ?? 'Unknown Member',
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