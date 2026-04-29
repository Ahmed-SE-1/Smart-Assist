import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../providers/smart_home_provider.dart';
import '../../../models/device.dart';

class GestureScreen extends ConsumerStatefulWidget {
  const GestureScreen({super.key});

  @override
  ConsumerState<GestureScreen> createState() => _GestureScreenState();
}

class _GestureScreenState extends ConsumerState<GestureScreen> with SingleTickerProviderStateMixin {
  late AnimationController _scanController;
  String _statusMessage = 'Detecting...';
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  void _simulateGesture(String gestureName) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Recognized: $gestureName';
    });

    final devicesNotifier = ref.read(devicesProvider.notifier);

    try {
      if (gestureName == 'Wave') {
        // Turn ON all lights
        final devices = ref.read(devicesProvider);
        for (var device in devices) {
          if (device.type == DeviceType.light && !device.isOn) {
            await devicesNotifier.turnOn(device.id, method: 'gesture');
          }
        }
      } else if (gestureName == 'Two Fingers') {
        // Turn ON all fans
        final devices = ref.read(devicesProvider);
        for (var device in devices) {
          if (device.type == DeviceType.fan && !device.isOn) {
            await devicesNotifier.turnOn(device.id, method: 'gesture');
            await devicesNotifier.setFanSpeed(device, 3, method: 'gesture'); // Default speed
          }
        }
      } else if (gestureName == 'Fist') {
        // Turn OFF all devices
        await devicesNotifier.turnOffAll(method: 'gesture');
      }

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Executed gesture action: $gestureName'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );

    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = 'Detecting...';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19), // Dark background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: const Text('Gesture Control', style: TextStyle(color: Colors.white)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'Wave your hand to control devices',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 32),
              
              // Mock Camera Feed
              Container(
                width: double.infinity,
                height: 350,
                decoration: BoxDecoration(
                  color: const Color(0xFF151A27),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Mock Hand Image/Icon
                    Icon(Icons.pan_tool, size: 150, color: Colors.orange.shade300),
                    
                    // Scanning Line
                    AnimatedBuilder(
                      animation: _scanController,
                      builder: (context, child) {
                        return Positioned(
                          top: 20 + (_scanController.value * 280),
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 2,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.green.withOpacity(0.5),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                )
                              ],
                              color: Colors.greenAccent,
                            ),
                          ),
                        );
                      },
                    ),
                    
                    // Bounding Box mock
                    Container(
                      width: 200,
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    
                    Positioned(
                      bottom: 16,
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              
              // Available Gestures
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Available Gestures (Tap to Simulate)',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),
              _buildGestureRow('👋', 'Wave', 'Turn ON Lights', () => _simulateGesture('Wave')),
              _buildGestureRow('✌️', 'Two Fingers', 'Turn ON Fans', () => _simulateGesture('Two Fingers')),
              _buildGestureRow('✊', 'Fist', 'Turn OFF All', () => _simulateGesture('Fist')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureRow(String emoji, String gestureName, String action, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF151A27),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _isProcessing ? Colors.grey.shade800 : Colors.transparent),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                gestureName,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              action,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
