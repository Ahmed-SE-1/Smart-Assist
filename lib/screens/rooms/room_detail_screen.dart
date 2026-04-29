import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../models/device.dart';
import '../../providers/smart_home_provider.dart';

class RoomDetailScreen extends ConsumerStatefulWidget {
  final String roomName;
  const RoomDetailScreen({super.key, required this.roomName});

  @override
  ConsumerState<RoomDetailScreen> createState() => _RoomDetailScreenState();
}

class _RoomDetailScreenState extends ConsumerState<RoomDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(roomsProvider);
    final room = rooms.firstWhere(
      (r) => r.name == widget.roomName,
      orElse: () => rooms.first,
    );
    final devices = ref.watch(devicesByRoomProvider(room.id));

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF2D3436)),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF2D3436)),
            onPressed: () => _showAddDeviceDialog(room.id),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF2D3436)),
            onSelected: (value) {
              if (value == 'edit') {
                _showEditRoomDialog(room.id, room.name, room.iconAsset);
              } else if (value == 'delete') {
                ref.read(roomsProvider.notifier).removeRoom(room.id);
                context.pop();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit Room')),
              const PopupMenuItem(value: 'delete', child: Text('Delete Room', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          children: [
            Text(
              widget.roomName,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: const Color(0xFF2D3436),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '${devices.length} Devices • Node: ${room.esp32NodeId}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (devices.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(48.0),
                  child: Column(
                    children: [
                      Icon(Icons.devices_other, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text('No devices yet', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('Tap + to add a device', style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ...devices.map((device) => _buildDeviceCard(device)),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(Device device) {
    switch (device.type) {
      case DeviceType.light:
        return _buildToggleDeviceCard(device);
      case DeviceType.fan:
        return _buildFanCard(device);
      case DeviceType.ac:
        return _buildACDeviceCard(device);
      case DeviceType.sensor:
        return _buildSensorCard(device);
    }
  }

  Widget _buildToggleDeviceCard(Device device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5)),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: device.isOn ? Colors.orange : Colors.grey, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text(device.isOn ? 'ON' : 'OFF', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ],
            ),
          ),
          Switch(
            value: device.isOn,
            onChanged: (v) => _toggleDevice(device),
            activeColor: Theme.of(context).colorScheme.primary,
          ),
          _buildDeviceOptions(device),
        ],
      ),
    );
  }

  Widget _buildFanCard(Device device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.air, color: device.isOn ? Colors.teal : Colors.grey, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(device.isOn ? 'Speed ${device.fanSpeed}' : 'OFF', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ),
              Switch(
                value: device.isOn,
                onChanged: (v) => _toggleDevice(device),
                activeColor: Theme.of(context).colorScheme.primary,
              ),
              _buildDeviceOptions(device),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Spd ${device.fanSpeed}', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
              Expanded(
                child: Slider(
                  value: device.fanSpeed.toDouble(),
                  min: 0,
                  max: 5,
                  divisions: 5,
                  label: '${device.fanSpeed}',
                  onChanged: (v) => _setFanSpeed(device, v.round()),
                  activeColor: Colors.teal,
                  inactiveColor: Colors.teal.withOpacity(0.2),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildACDeviceCard(Device device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.ac_unit, color: device.isOn ? Colors.blue : Colors.grey, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(device.isOn ? '${device.acTemperature}°C' : 'OFF', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ),
              Row(
                children: [
                  Text('${device.acTemperature}°C', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(width: 8),
                  Switch(
                    value: device.isOn,
                    onChanged: (v) => _toggleDevice(device),
                    activeColor: Theme.of(context).colorScheme.primary,
                  ),
                  _buildDeviceOptions(device),
                ],
              ),
            ],
          ),
          if (device.isOn) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('16°C', style: TextStyle(fontSize: 12, color: Colors.grey)),
                Expanded(
                  child: Slider(
                    value: device.acTemperature.toDouble(),
                    min: 16,
                    max: 30,
                    divisions: 14,
                    label: '${device.acTemperature}°C',
                    onChanged: (v) => _setACTemperature(device, v.round()),
                    activeColor: Colors.blue,
                    inactiveColor: Colors.blue.withOpacity(0.2),
                  ),
                ),
                const Text('30°C', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSensorCard(Device device) {
    final isMot = device.sensorType == 'motion';
    final displayVal = isMot
        ? (device.sensorValue > 0.5 ? 'Motion Detected' : 'No Motion')
        : '${device.sensorValue.toStringAsFixed(1)}°C';
    final color = isMot
        ? (device.sensorValue > 0.5 ? Colors.red : Colors.green)
        : (device.sensorValue > 30 ? Colors.orange : Colors.green);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5)),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.sensors, color: color, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text(device.sensorType.toUpperCase(), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(displayVal, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
          ),
          _buildDeviceOptions(device),
        ],
      ),
    );
  }

  Future<void> _toggleDevice(Device device) async {
    final success = await ref.read(devicesProvider.notifier).toggleDevice(device);
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${device.name} is now ${!device.isOn ? "ON" : "OFF"}'),
            duration: const Duration(seconds: 1),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _setFanSpeed(Device device, int speed) async {
    final success = await ref.read(devicesProvider.notifier).setFanSpeed(device, speed);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _setACTemperature(Device device, int temperature) async {
    final success = await ref.read(devicesProvider.notifier).setACTemperature(device, temperature);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
      );
    }
  }

  void _showAddDeviceDialog(String roomId) {
    final controller = TextEditingController();
    DeviceType selectedType = DeviceType.light;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: 'Device Name'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<DeviceType>(
                value: selectedType,
                decoration: const InputDecoration(labelText: 'Device Type'),
                items: DeviceType.values.map((t) => DropdownMenuItem(
                  value: t,
                  child: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                )).toList(),
                onChanged: (v) => setDialogState(() => selectedType = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final error = ref.read(devicesProvider.notifier).addDevice(controller.text, selectedType, roomId);
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${controller.text} added!'), backgroundColor: Colors.green),
                  );
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditRoomDialog(String roomId, String currentName, String currentIconAsset) {
    final controller = TextEditingController(text: currentName);
    String selectedIcon = currentIconAsset;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Room'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: 'Room Name'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedIcon,
                decoration: const InputDecoration(labelText: 'Room Type'),
                items: const [
                  DropdownMenuItem(value: 'living_room', child: Text('Living Room')),
                  DropdownMenuItem(value: 'bed', child: Text('Bedroom')),
                  DropdownMenuItem(value: 'kitchen', child: Text('Kitchen')),
                  DropdownMenuItem(value: 'bathroom', child: Text('Bathroom')),
                  DropdownMenuItem(value: 'garage', child: Text('Garage')),
                ],
                onChanged: (v) => setDialogState(() => selectedIcon = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final error = ref.read(roomsProvider.notifier).editRoom(roomId, controller.text, selectedIcon);
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                  // Refresh room detail screen by pushing replacement to the new route name if changed
                  if (controller.text != currentName && mounted) {
                    context.replace('/room/${controller.text}');
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceOptions(Device device) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.grey),
      onSelected: (value) {
        if (value == 'edit') {
          _showEditDeviceDialog(device);
        } else if (value == 'delete') {
          ref.read(devicesProvider.notifier).removeDevice(device.id);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    );
  }

  void _showEditDeviceDialog(Device device) {
    final controller = TextEditingController(text: device.name);
    DeviceType selectedType = device.type;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(labelText: 'Device Name'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<DeviceType>(
                value: selectedType,
                decoration: const InputDecoration(labelText: 'Device Type'),
                items: DeviceType.values.map((t) => DropdownMenuItem(
                  value: t,
                  child: Text(t.name[0].toUpperCase() + t.name.substring(1)),
                )).toList(),
                onChanged: (v) => setDialogState(() => selectedType = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final error = ref.read(devicesProvider.notifier).editDevice(device.id, controller.text, selectedType);
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
