import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../providers/smart_home_provider.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> with SingleTickerProviderStateMixin {
  bool _isListening = false;
  late AnimationController _pulseController;
  String _statusMessage = 'Tap to Listen';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _toggleListening() async {
    if (_isListening) return;

    setState(() {
      _isListening = true;
      _statusMessage = 'Listening...';
    });

    // Simulate listening for 2 seconds
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    setState(() {
      _statusMessage = 'Processing command...';
    });

    // Mock voice commands based on suggestions
    final random = DateTime.now().millisecondsSinceEpoch % 3;
    String commandText = '';
    
    switch (random) {
      case 0:
        commandText = "Turn on the living room light";
        await _handleCommand('main light', true);
        break;
      case 1:
        commandText = "Turn off the fan";
        await _handleCommand('fan', false);
        break;
      case 2:
        commandText = "Set AC to 22 degrees";
        await _handleAcCommand('ac', 22);
        break;
    }

    if (!mounted) return;

    setState(() {
      _isListening = false;
      _statusMessage = 'Heard: "$commandText"\nCommand Executed!';
    });

    // Reset status message after a while
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _statusMessage = 'Tap to Listen';
        });
      }
    });
  }

  Future<void> _handleCommand(String deviceNamePart, bool turnOn) async {
    final devicesNotifier = ref.read(devicesProvider.notifier);
    final devices = devicesNotifier.findByName(deviceNamePart);
    
    if (devices.isNotEmpty) {
      final device = devices.first;
      if (turnOn) {
         await devicesNotifier.turnOn(device.id, method: 'voice');
      } else {
         await devicesNotifier.turnOff(device.id, method: 'voice');
      }
    }
  }

  Future<void> _handleAcCommand(String deviceNamePart, int temp) async {
    final devicesNotifier = ref.read(devicesProvider.notifier);
    final devices = devicesNotifier.findByName(deviceNamePart);
    
    if (devices.isNotEmpty) {
      final device = devices.first;
      await devicesNotifier.setACTemperature(device, temp, method: 'voice');
      await devicesNotifier.turnOn(device.id, method: 'voice');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19), // Dark background from UI
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: const Text('Voice Control', style: TextStyle(color: Colors.white)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            const Text(
              'Tap mic and give command',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: _toggleListening,
                      child: AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  Theme.of(context).colorScheme.primary,
                                  Theme.of(context).colorScheme.primary.withOpacity(0.5),
                                  Colors.transparent,
                                ],
                                stops: [0.3, 0.6 + (_isListening ? _pulseController.value * 0.4 : 0.0), 1.0],
                              ),
                            ),
                            child: const Center(
                              child: Icon(Icons.mic, size: 80, color: Colors.white),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Try saying:', style: TextStyle(color: Colors.white54, fontSize: 16)),
                  const SizedBox(height: 16),
                  _buildSuggestion('"Turn on the living room light"'),
                  _buildSuggestion('"Turn off the fan"'),
                  _buildSuggestion('"Set AC to 22 degrees"'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Mock Audio Visualizer
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(30, (index) {
                final height = _isListening 
                    ? (10.0 + (index % 5) * 10.0 * _pulseController.value) 
                    : 4.0;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 4,
                  height: height,
                  decoration: BoxDecoration(
                    color: index % 2 == 0 ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.secondary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: ElevatedButton.icon(
                onPressed: () => context.push('/home/gesture'),
                icon: const Icon(Icons.pan_tool, color: Colors.white),
                label: const Text('Use Gesture Control', style: TextStyle(fontSize: 16, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade600,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  minimumSize: const Size(double.infinity, 56),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestion(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
    );
  }

}
