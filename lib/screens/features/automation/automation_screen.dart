import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/automation_rule.dart';
import '../../../providers/automation_provider.dart';
import '../../../providers/smart_home_provider.dart';


class AutomationScreen extends ConsumerWidget {
  const AutomationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(automationProvider);
    final devices = ref.watch(devicesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(title: const Text('Automation Rules'),
          backgroundColor: Colors.transparent,
          elevation: 0),
      body: rules.isEmpty
          ? const Center(child: Text('No automation rules set yet.'))
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: rules.length,
        itemBuilder: (context, index) {
          final rule = rules[index];
          final deviceName = devices
              .firstWhere((d) => d.id == rule.targetDeviceId,
              orElse: () => devices.first)
              .name;

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rule.name,
                          style: const TextStyle(fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('If: $deviceName ${rule.property} ${rule
                          .operator} ${rule.value}'),
                      Text('Then: ${rule.action
                          .replaceAll('_', ' ')
                          .toUpperCase()}', style: TextStyle(color: Theme
                          .of(context)
                          .colorScheme
                          .primary, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                // Actions: Edit, Delete, Switch
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                          Icons.edit, color: Colors.blue, size: 20),
                      onPressed: () =>
                          _showRuleDialog(context, ref, existingRule: rule),
                    ),
                    IconButton(
                      icon: const Icon(
                          Icons.delete, color: Colors.red, size: 20),
                      onPressed: () =>
                          ref.read(automationProvider.notifier).removeRule(
                              rule.id),
                    ),
                    Switch(
                      value: rule.isActive,
                      onChanged: (val) =>
                          ref.read(automationProvider.notifier).toggleRule(
                              rule.id),
                    ),
                  ],
                )
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

  void _showRuleDialog(BuildContext context, WidgetRef ref,
      {AutomationRule? existingRule}) {
    final isEditing = existingRule != null;
    final nameController = TextEditingController(
        text: existingRule?.name ?? '');
    final valueController = TextEditingController(
        text: existingRule?.value.toString() ?? '');

    // Providers se devices aur rooms dono uthayein
    final devices = ref.read(devicesProvider);
    final allRooms = ref.read(roomsProvider);

    // Devices se unique Room IDs extract kar rahay hain
    final roomIds = devices.map((d) => d.roomId).toSet().toList();

    String? selectedRoom;
    String? selectedDeviceId = existingRule?.targetDeviceId;
    String selectedProperty = existingRule?.property ?? 'state';
    String selectedOperator = existingRule?.operator ?? '>';
    String selectedAction = existingRule?.action ?? 'alert';

    // Agar pehle se device selected hai (Edit mode), toh uska room pre-select karein
    if (isEditing && selectedDeviceId != null) {
      try {
        selectedRoom = devices
            .firstWhere((d) => d.id == selectedDeviceId)
            .roomId;
      } catch (_) {}
    }

    showDialog(
      context: context,
      builder: (ctx) =>
          StatefulBuilder(
              builder: (ctx, setDialogState) {
                // Jo room select hua hai sirf uski devices show hon
                final filteredDevices = selectedRoom == null
                    ? devices
                    : devices.where((d) => d.roomId == selectedRoom).toList();

                // Safety check: Agar filter ki wajah se selected device list mein nahi hai toh null kar do
                if (selectedDeviceId != null &&
                    !filteredDevices.any((d) => d.id == selectedDeviceId)) {
                  selectedDeviceId = null;
                }

                return AlertDialog(
                  title: Text(isEditing ? 'Edit Rule' : 'Create Rule'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(controller: nameController,
                            decoration: const InputDecoration(
                                labelText: 'Rule Name (e.g. Fan Speed Alert)')),
                        const SizedBox(height: 16),

                        // 1. Room Selection (Filter) - YAHAN FIX KIYA HAI
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: selectedRoom,
                          decoration: const InputDecoration(
                              labelText: 'Filter by Room'),
                          items: roomIds.map((id) {
                            // ID ke zariye Room ka actual naam nikalna
                            String roomName = 'Unknown Room';
                            try {
                              roomName = allRooms
                                  .firstWhere((r) => r.id == id)
                                  .name;
                            } catch (_) {}

                            return DropdownMenuItem(
                                value: id,
                                // Value mein id hi jayegi (logic ke liye)
                                child: Text(roomName) // UI mein Naam show hoga
                            );
                          }).toList(),
                          onChanged: (v) =>
                              setDialogState(() => selectedRoom = v),
                        ),
                        const SizedBox(height: 16),

                        // 2. Device Selection
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: selectedDeviceId,
                          decoration: const InputDecoration(
                              labelText: 'Select Device'),
                          items: filteredDevices.map((d) =>
                              DropdownMenuItem(value: d.id, child: Text(
                                  '${d.name} (${d.type.name})'))).toList(),
                          onChanged: (v) =>
                              setDialogState(() => selectedDeviceId = v),
                        ),
                        const SizedBox(height: 16),

                        // 3. Property
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: selectedProperty,
                          decoration: const InputDecoration(
                              labelText: 'Property'),
                          items: const [
                            DropdownMenuItem(
                                value: 'speed', child: Text('Speed')),
                            DropdownMenuItem(
                                value: 'temperature', child: Text('AC Temp')),
                            DropdownMenuItem(
                                value: 'sensor', child: Text('Sensor Value')),
                            DropdownMenuItem(value: 'state',
                                child: Text('Status (1=On, 0=Off)')),
                          ],
                          onChanged: (v) =>
                              setDialogState(() => selectedProperty = v!),
                        ),
                        const SizedBox(height: 16),

                        // 4. Operator and Value
                        Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: selectedOperator,
                                decoration: const InputDecoration(
                                    labelText: 'Operator'),
                                items: const [
                                  DropdownMenuItem(
                                      value: '>', child: Text('Greater (>)')),
                                  DropdownMenuItem(
                                      value: '<', child: Text('Less (<)')),
                                  DropdownMenuItem(
                                      value: '==', child: Text('Equal (==)')),
                                ],
                                onChanged: (v) =>
                                    setDialogState(() => selectedOperator = v!),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 1,
                              child: TextField(
                                controller: valueController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'Value (e.g. 4)'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 5. Action
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: selectedAction,
                          decoration: const InputDecoration(
                              labelText: 'Action to perform'),
                          items: const [
                            DropdownMenuItem(value: 'alert',
                                child: Text('Send Hardware Alert')),
                            DropdownMenuItem(value: 'turn_on',
                                child: Text('Turn ON Device')),
                            DropdownMenuItem(value: 'turn_off',
                                child: Text('Turn OFF Device')),
                          ],
                          onChanged: (v) =>
                              setDialogState(() => selectedAction = v!),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    ElevatedButton(
                      onPressed: () {
                        if (selectedDeviceId == null ||
                            valueController.text.isEmpty) return;

                        ref.read(automationProvider.notifier).addOrUpdateRule(
                          existingId: isEditing ? existingRule.id : null,
                          name: nameController.text,
                          targetDeviceId: selectedDeviceId!,
                          property: selectedProperty,
                          operator: selectedOperator,
                          value: double.parse(valueController.text),
                          action: selectedAction,
                        );
                        Navigator.pop(ctx);
                      },
                      child: Text(isEditing ? 'Update Rule' : 'Save Rule'),
                    ),
                  ],
                );
              }
          ),
    );
  }
}