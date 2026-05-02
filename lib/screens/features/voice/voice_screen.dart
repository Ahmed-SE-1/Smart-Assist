import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart'; // Naya import
import 'package:speech_to_text/speech_recognition_result.dart'; // Naya import
import '../../../providers/smart_home_provider.dart';
import '../../../providers/accessibility_provider.dart';
import '../../../models/device.dart';
import '../../../models/room.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> with SingleTickerProviderStateMixin {
  // Speech variables
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _wordsSpoken = '';

  bool _isListening = false;
  late AnimationController _pulseController;
  String _statusMessage = 'Tap mic and give command';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initSpeech(); // Speech engine start karein
  }

  // 1. Speech Engine Initialize Karna
  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize(
      onError: (error) => print("Speech Error: $error"),
      onStatus: (status) => print("Speech Status: $status"),
    );
    setState(() {});
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speechToText.cancel(); // Memory free karna zaroori hai
    super.dispose();
  }

  // 2. Mic On/Off Toggle karna
  void _toggleListening() async {
    if (!_speechEnabled) {
      setState(() => _statusMessage = 'Microphone permission denied');
      return;
    }

    if (_speechToText.isNotListening) {
      setState(() {
        _isListening = true;
        _statusMessage = 'Listening...';
        _wordsSpoken = ''; // Purani baat clear karein
      });
      await _speechToText.listen(onResult: _onSpeechResult);
    } else {
      await _speechToText.stop();
      setState(() => _isListening = false);
    }
  }

  // 3. User ki Awaz ko Text mein badalna
  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _wordsSpoken = result.recognizedWords;
      _statusMessage = 'Heard: "$_wordsSpoken"';
    });

    // Jab user bolna band kar de (final result aa jaye)
    if (result.finalResult) {
      setState(() => _isListening = false);
      _processCommand(_wordsSpoken); // Text ko process karein
    }
  }

  // --- ADVANCED NLP COMMAND PROCESSING ---
  Future<void> _processCommand(String command) async {
    setState(() => _statusMessage = 'Analyzing command...');

    // 1. Text Normalization (Speech-to-Text mistakes aur Numbers fix karna)
    String text = command.toLowerCase().trim();
    text = text.replaceAll(' to ', ' 2 '); // "Light to" ko "Light 2" banayega
    text = text.replaceAll(' too ', ' 2 ');
    text = text.replaceAll(' two ', ' 2 ');
    text = text.replaceAll(' one ', ' 1 ');
    text = text.replaceAll(' three ', ' 3 ');
    text = text.replaceAll(' four ', ' 4 ');
    text = text.replaceAll(' five ', ' 5 ');

    // 2. Action Catching
    bool turnOn = text.contains('turn on') || text.contains('switch on') || text.contains('start') || text.contains(' on');
    bool turnOff = text.contains('turn off') || text.contains('switch off') || text.contains('stop') || text.contains(' off');
    bool isTempOrSpeedCommand = text.contains('set') || text.contains('temperature') || text.contains('ac') || text.contains('speed');

    if (!turnOn && !turnOff && !isTempOrSpeedCommand) {
      _showStatus('Command not clear. Please say Turn On, Turn Off, Set Temperature, or Set Speed.');
      return;
    }

    // 3. Provider State Read
    final allDevices = ref.read(devicesProvider);
    final allRooms = ref.read(roomsProvider);

    // 4. Strict Room Detection (Check if room is explicitly mentioned)
    Room? mentionedRoom;
    for (var room in allRooms) {
      if (text.contains(room.name.toLowerCase())) {
        mentionedRoom = room;
        break;
      }
    }

    // Agar user ne "room" bola lekin wo deleted hai ya exist nahi karta
    if (text.contains('room') && mentionedRoom == null) {
      _showStatus('Room not found. Please check if the room exists.');
      return;
    }

    // 5. Dynamic & Strict Device Matcher
    List<Device> possibleDevices = [];
    for (var device in allDevices) {
      if (text.contains(device.name.toLowerCase())) {
        if (mentionedRoom != null) {
          // Strict Match: Agar room specify kiya hai, sirf usi room ki device uthayein
          if (device.roomId == mentionedRoom.id) {
            possibleDevices.add(device);
          }
        } else {
          // Normal Match: Agar room nahi bola, toh saari matching devices add karein
          possibleDevices.add(device);
        }
      }
    }

    if (possibleDevices.isEmpty) {
      _showStatus('Could not find any device matching your command.\nPlease check the exact device name.');
      return;
    }

    // Ambiguity Check (Same device name in different rooms)
    if (possibleDevices.length > 1 && mentionedRoom == null) {
      _showStatus('Multiple devices found. Please specify the room (e.g., Fan in Bedroom).');
      return;
    }

    // Target device final ho gayi
    Device targetDevice = possibleDevices.first;

    // 6. Fan Speed Logic (Sirf 0-5 limit)
    if (text.contains('speed') || targetDevice.type == DeviceType.fan) {
      final RegExp speedRegex = RegExp(r'speed\s*([0-5])|([0-5])\s*speed|set\s*([0-5])');
      final match = speedRegex.firstMatch(text);

      if (match != null) {
        String? speedStr = match.group(1) ?? match.group(2) ?? match.group(3);
        if (speedStr != null) {
          int speed = int.parse(speedStr);
          await ref.read(devicesProvider.notifier).setFanSpeed(targetDevice, speed, method: 'voice');
          _showStatus('Success: ${targetDevice.name} speed set to $speed');
          _giveVoiceFeedback("${targetDevice.name} speed set to $speed");
          return;
        }
      }
    }

    // 7. AC Temperature Logic (Sirf 16-32 limit)
    if (targetDevice.type == DeviceType.ac || text.contains('ac') || text.contains('temperature')) {
      final RegExp tempRegex = RegExp(r'\b(1[6-9]|2[0-9]|3[0-2])\b');
      final match = tempRegex.firstMatch(text);

      if (match != null) {
        int temp = int.parse(match.group(0)!);
        await ref.read(devicesProvider.notifier).setACTemperature(targetDevice, temp, method: 'voice');
        await ref.read(devicesProvider.notifier).turnOn(targetDevice.id, method: 'voice');

        _showStatus('Success: ${targetDevice.name} set to $temp degrees');
        _giveVoiceFeedback("${targetDevice.name} set to $temp degrees");
        return;
      }
    }

    // 8. On/Off Execution (Provider functions call karna)
    if (turnOn) {
      await ref.read(devicesProvider.notifier).turnOn(targetDevice.id, method: 'voice');
      _showStatus('Success: ${targetDevice.name} turned ON');
      _giveVoiceFeedback("${targetDevice.name} turned on");
    } else if (turnOff) {
      await ref.read(devicesProvider.notifier).turnOff(targetDevice.id, method: 'voice');
      _showStatus('Success: ${targetDevice.name} turned OFF');
      _giveVoiceFeedback("${targetDevice.name} turned off");
    }
  }

  // --- Helpers ---
  void _showStatus(String msg) {
    if (!mounted) return;
    setState(() => _statusMessage = msg);

    // 4 seconds baad UI wapas reset karein
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _statusMessage = 'Tap mic and give command');
    });
  }

  void _giveVoiceFeedback(String textToSpeak) {
    // Agar TTS provider lagaya hua hai tou wo bol kar batayega
    ref.read(ttsServiceProvider).speak(textToSpeak);
  }

  // Existing Command Handlers (Aapke original code se)
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
      backgroundColor: const Color(0xFF0B0F19),
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
                            child: Center(
                              child: Icon(
                                  _isListening ? Icons.mic : Icons.mic_none,
                                  size: 80,
                                  color: Colors.white
                              ),
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
            // Text overflow fix
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Audio Visualizer
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