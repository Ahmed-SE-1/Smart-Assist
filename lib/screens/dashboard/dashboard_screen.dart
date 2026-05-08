import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/device.dart';
import '../../providers/smart_home_provider.dart';
import '../../providers/user_provider.dart';

/// The primary Home screen of the application.
/// Displays user statistics, saved rooms, and quick access feature controls.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  /// Maps a room type string (saved in DB) to a visual Material Icon.
  IconData _roomIcon(String iconAsset) {
    switch (iconAsset) {
      case 'living_room': return Icons.chair_outlined;
      case 'bed': return Icons.bed_outlined;
      case 'kitchen': return Icons.kitchen_outlined;
      case 'bathroom': return Icons.bathtub_outlined;
      case 'garage': return Icons.garage_outlined;
      default: return Icons.home_outlined;
    }
  }

  /// Determines how to render the user's avatar.
  /// Handles fallback network images, real web URLs, and local file paths.
  ImageProvider _getAvatarImage(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return const NetworkImage('https://i.pravatar.cc/150?img=11');
    } else if (avatarUrl.startsWith('http')) {
      return NetworkImage(avatarUrl);
    } else {
      return FileImage(File(avatarUrl));
    }
  }

  /// Returns a unique vibrant color gradient based on the room's index in the list.
  /// Gives the horizontal room list a modern, colorful look.
  List<Color> _roomGradient(int index) {
    const gradients = [
      [Color(0xFF6C5CE7), Color(0xFF8E84F3)],
      [Color(0xFF0052D4), Color(0xFF4364F7)],
      [Color(0xFF00E676), Color(0xFF1DE9B6)],
      [Color(0xFFFF6B6B), Color(0xFFFF8E8E)],
      [Color(0xFFFF9800), Color(0xFFFFB74D)],
    ];
    return gradients[index % gradients.length];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 1. Watch Riverpod providers so the Dashboard rebuilds instantly if data changes.
    final user = ref.watch(userProvider);
    final rooms = ref.watch(roomsProvider);
    final devices = ref.watch(devicesProvider);
    
    // 2. Computed statistics for the top cards
    final activeCount = ref.watch(activeDeviceCountProvider);
    final temperature = ref.watch(temperatureProvider);

    // Get quick-control devices (first 4 non-sensor devices)
    final quickDevices = devices.where((d) => d.type != DeviceType.sensor).take(4).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello,',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${user?.name ?? "User"} 👋',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2D3436),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundImage: _getAvatarImage(user?.avatarUrl),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Stats Row
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Active Devices', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text('$activeCount', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF2D3436))),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Temperature', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text('${temperature.toStringAsFixed(1)}°C',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: temperature > 30 ? Colors.red : const Color(0xFF2D3436),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // My Rooms Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'My Rooms',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF2D3436),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showAddRoomDialog(context, ref),
                    child: Text('+ Add', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 140,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: rooms.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 16),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    final roomDevices = ref.watch(devicesByRoomProvider(room.id));
                    return _buildRoomCard(
                      context,
                      title: room.name,
                      devices: '${roomDevices.length} Devices',
                      icon: _roomIcon(room.iconAsset),
                      gradient: _roomGradient(index),
                      onTap: () => context.push('/room/${room.name}'),
                    );
                  },
                ),
              ),

              const SizedBox(height: 32),

              // Quick Controls Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Quick Controls',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF2D3436),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildControlFeatureCard(
                      context,
                      title: 'Voice Assistant',
                      icon: Icons.mic,
                      color: Colors.purple,
                      onTap: () => context.push('/home/voice'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildControlFeatureCard(
                      context,
                      title: 'Gesture Control',
                      icon: Icons.pan_tool,
                      color: Colors.orange,
                      onTap: () => context.push('/home/gesture'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Displays a modal popup to let the user create a new Room.
  void _showAddRoomDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    String selectedIcon = 'living_room';

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
          title: const Text('Add New Room', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
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
                    hintText: 'e.g., Master Bedroom',
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
                final error = ref.read(roomsProvider.notifier).addRoom(controller.text, selectedIcon);
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
              child: const Text('Add Room'),
            ),
          ],
        ),
      ),
    );
  }

  /// A generic builder for the colorful Room Cards seen in the horizontal list.
  Widget _buildRoomCard(BuildContext context, {required String title, required String devices, required IconData icon, required List<Color> gradient, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: gradient[0].withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(devices, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _deviceIcon(DeviceType type) {
    switch (type) {
      case DeviceType.light: return Icons.lightbulb_outline;
      case DeviceType.fan: return Icons.air;
      case DeviceType.ac: return Icons.ac_unit;
      case DeviceType.sensor: return Icons.sensors;
    }
  }

  Color _deviceColor(DeviceType type) {
    switch (type) {
      case DeviceType.light: return Colors.orange;
      case DeviceType.fan: return Colors.blue;
      case DeviceType.ac: return Colors.cyan;
      case DeviceType.sensor: return Colors.green;
    }
  }

  /// Builds the white rounded square cards used for Quick Controls (e.g. Voice Assistant).
  Widget _buildControlFeatureCard(BuildContext context, {required String title, required IconData icon, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF2D3436)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
