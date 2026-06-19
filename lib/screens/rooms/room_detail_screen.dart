import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../models/device.dart';
import '../../providers/smart_home_provider.dart';
import '../../providers/accessibility_provider.dart';

/// A dynamic screen that shows all the specific devices contained within a single Room.
/// It observes the `devicesByRoomProvider` to automatically redraw when devices are added, edited, or toggled.
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
          tooltip: 'Go Back', // TalkBack will read this
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF2D3436)),
            tooltip: 'Add new device', // TalkBack will read this
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

  /// Evaluates the device's [DeviceType] and returns the appropriate specialized UI Card.
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

  /// Helper to get the correct icon for a device type.
  IconData _getIconForType(DeviceType type) {
    switch (type) {
      case DeviceType.light: return Icons.lightbulb_outline;
      case DeviceType.fan: return Icons.air;
      case DeviceType.ac: return Icons.ac_unit;
      case DeviceType.sensor: return Icons.sensors;
    }
  }

  /// Builds a simple ON/OFF switch card for Lights.
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

  /// Builds an advanced card for Fans that includes both an ON/OFF toggle and a Speed slider (0-5).
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
                child: Semantics(
                  label: '${device.name} Speed Control',
                  value: '${device.fanSpeed}',
                  increasedValue: 'Speed Increased',
                  decreasedValue: 'Speed Decreased',
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
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Builds an advanced card for Air Conditioners with a Temperature slider (16°C-30°C).
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
                  child: Semantics(
                    label: '${device.name} Temperature Control',
                    value: '${device.acTemperature} degrees',
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
                ),
                const Text('30°C', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Builds a read-only card that displays live sensor telemetry (e.g. Temperature, Motion).
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

  /// Communicates with the SmartHome provider to toggle a device ON/OFF and speaks TTS feedback.
  Future<void> _toggleDevice(Device device) async {
    final success = await ref.read(devicesProvider.notifier).toggleDevice(device);
    if (mounted) {
      if (success) {
        // Yahan status variable declare karna zaroori hai
        final status = !device.isOn ? "ON" : "OFF";

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // Yahan bhi hum ab direct variable use kar sakte hain
            content: Text('${device.name} is now $status'),
            duration: const Duration(seconds: 1),
          ),
        );
        // == TTS ==
        ref.read(ttsServiceProvider).speak("${device.name} is turned $status in ${widget.roomName}");
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Updates the rotational speed of a Fan device via the SmartHome provider.
  Future<void> _setFanSpeed(Device device, int speed) async {
    final success = await ref.read(devicesProvider.notifier).setFanSpeed(device, speed);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
      );
    }
    else {
      // === TTS FOR FAN SPEED ===
      ref.read(ttsServiceProvider).speak("${device.name} speed set to $speed");
  }
  }

  /// Updates the target temperature of an AC unit via the SmartHome provider.
  Future<void> _setACTemperature(Device device, int temperature) async {
    final success = await ref.read(devicesProvider.notifier).setACTemperature(device, temperature);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device not responding'), backgroundColor: Colors.red),
      );
    }
    else {
      // === TTS FOR AC TEMP ===
      ref.read(ttsServiceProvider).speak("${device.name} temperature set to $temperature degrees");
    }
  }

  /// Displays a popup modal that lets the user create a brand new Smart Device inside this room.
  void _showAddDeviceDialog(String roomId) {
    final controller = TextEditingController();
    DeviceType selectedType = DeviceType.light;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Add New Device', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: 'Device Name',
                    hintText: 'e.g., Ceiling Fan',
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text('Select Device Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: DeviceType.values.map((type) {
                    final isSelected = selectedType == type;
                    return GestureDetector(
                      onTap: () => setDialogState(() => selectedType = type),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: isSelected
                              ? [BoxShadow(color: Theme.of(context).colorScheme.primary.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))]
                              : [],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_getIconForType(type), size: 20, color: isSelected ? Colors.white : Colors.grey.shade700),
                            const SizedBox(width: 8),
                            Text(
                              type.name[0].toUpperCase() + type.name.substring(1),
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.grey.shade800,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
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
                if (controller.text.trim().isEmpty) return;
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
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Add Device'),
            ),
          ],
        ),
      ),
    );
  }

  /// Displays a modal to edit the current Room's metadata (Name and Icon).
  void _showEditRoomDialog(String roomId, String currentName, String currentIconAsset) {
    final controller = TextEditingController(text: currentName);
    String selectedIcon = currentIconAsset;

    final Map<String, Map<String, dynamic>> roomTypes = {
      'living_room': {'label': 'Living Room', 'icon': Icons.chair_outlined},
      'bed': {'label': 'Bedroom', 'icon': Icons.bed_outlined},
      'kitchen': {'label': 'Kitchen', 'icon': Icons.kitchen_outlined},
      'bathroom': {'label': 'Bathroom', 'icon': Icons.bathtub_outlined},
      'garage': {'label': 'Garage', 'icon': Icons.garage_outlined},
    };

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Edit Room', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: 'Room Name',
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text('Select Room Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: roomTypes.entries.map((entry) {
                    final isSelected = selectedIcon == entry.key;
                    return GestureDetector(
                      onTap: () => setDialogState(() => selectedIcon = entry.key),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: isSelected
                              ? [BoxShadow(color: Theme.of(context).colorScheme.primary.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))]
                              : [],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(entry.value['icon'], size: 20, color: isSelected ? Colors.white : Colors.grey.shade700),
                            const SizedBox(width: 8),
                            Text(
                              entry.value['label'],
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.grey.shade800,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
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
                if (controller.text.trim().isEmpty) return;
                final error = ref.read(roomsProvider.notifier).editRoom(roomId, controller.text, selectedIcon);
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                  if (controller.text != currentName && mounted) {
                    context.replace('/room/${controller.text}');
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  /// A small trailing popup menu on device cards that allows editing or deleting the specific device.
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

  /// Displays a modal to rename or change the type of an existing Smart Device.
  void _showEditDeviceDialog(Device device) {
    final controller = TextEditingController(text: device.name);
    DeviceType selectedType = device.type;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Edit Device', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: 'Device Name',
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text('Select Device Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: DeviceType.values.map((type) {
                    final isSelected = selectedType == type;
                    return GestureDetector(
                      onTap: () => setDialogState(() => selectedType = type),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: isSelected
                              ? [BoxShadow(color: Theme.of(context).colorScheme.primary.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))]
                              : [],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_getIconForType(type), size: 20, color: isSelected ? Colors.white : Colors.grey.shade700),
                            const SizedBox(width: 8),
                            Text(
                              type.name[0].toUpperCase() + type.name.substring(1),
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.grey.shade800,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
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
                if (controller.text.trim().isEmpty) return;
                final error = ref.read(devicesProvider.notifier).editDevice(device.id, controller.text, selectedType);
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
                } else {
                  Navigator.pop(ctx);
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
