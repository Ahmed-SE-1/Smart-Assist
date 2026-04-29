import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/automation_provider.dart';
import '../../../providers/smart_home_provider.dart';
import '../../../models/device.dart';

class AutomationScreen extends ConsumerWidget {
  const AutomationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(automationProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('Automation Rules'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: rules.isEmpty
          ? const Center(child: Text('No automation rules set yet.'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: rules.length,
              itemBuilder: (context, index) {
                final rule = rules[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(rule.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('If: ${rule.condition}', style: TextStyle(color: Colors.grey.shade700)),
                          const SizedBox(height: 4),
                          Text('Then: ${rule.action}', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    trailing: Switch(
                      value: rule.isActive,
                      onChanged: (val) => ref.read(automationProvider.notifier).toggleRule(rule.id),
                      activeColor: Theme.of(context).colorScheme.primary,
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddRuleDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New Rule'),
      ),
    );
  }

  void _showAddRuleDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final conditionController = TextEditingController();
    final actionController = TextEditingController();
    
    final devices = ref.read(devicesProvider);
    String? selectedDeviceId;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Create Automation Rule'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Rule Name', hintText: 'e.g. Cold AC'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: conditionController,
                  decoration: const InputDecoration(labelText: 'Condition', hintText: 'e.g. temperature > 30'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedDeviceId,
                  decoration: const InputDecoration(labelText: 'Target Device'),
                  items: devices.where((d) => d.type != DeviceType.sensor).map((d) => DropdownMenuItem(
                    value: d.id,
                    child: Text(d.name),
                  )).toList(),
                  onChanged: (v) => setDialogState(() => selectedDeviceId = v),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: actionController,
                  decoration: const InputDecoration(labelText: 'Action', hintText: 'e.g. Turn ON'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Supported conditions:\n- temperature > X\n- temperature < X\n- motion detected',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (selectedDeviceId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a target device'), backgroundColor: Colors.red));
                  return;
                }

                final error = ref.read(automationProvider.notifier).addRule(
                  name: nameController.text,
                  condition: conditionController.text,
                  action: actionController.text,
                  targetDeviceId: selectedDeviceId!,
                );

                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rule created!'), backgroundColor: Colors.green));
                }
              },
              child: const Text('Save Rule'),
            ),
          ],
        ),
      ),
    );
  }
}
