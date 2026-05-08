import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import '../../../providers/smart_home_provider.dart';
import '../../../providers/accessibility_provider.dart';
import '../../../models/device.dart';
import '../../../models/room.dart';

/// The Voice Control screen allows users to trigger smart home commands
/// by speaking naturally into their microphone. It uses an internal NLP engine.
class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen>
    with SingleTickerProviderStateMixin {
  // --- Speech Engine Variables ---
  final SpeechToText _speechToText =
      SpeechToText(); // The core Flutter STT plugin
  bool _speechEnabled =
      false; // Checks if the user granted microphone permissions
  String _wordsSpoken = ''; // The live transcript of what the user is saying

  // --- UI Animation Variables ---
  bool _isListening = false;
  late AnimationController
  _pulseController; // Controls the glowing ring around the microphone
  String _statusMessage = 'Tap mic and give command';

  @override
  void initState() {
    super.initState();

    // Setup the glowing pulse animation for the microphone
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    // Initialize the microphone immediately when the screen opens
    _initSpeech();
  }

  /// Asks for microphone permission and initializes the Google/Apple Speech Engine.
  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize(
      onError: (error) => debugPrint("Speech Error: $error"),
      onStatus: (status) => debugPrint("Speech Status: $status"),
    );
    setState(() {}); // Rebuild UI once permission is determined
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _speechToText
        .cancel(); // CRITICAL: Stop listening when leaving the screen to save battery
    super.dispose();
  }

  /// Toggles the microphone ON or OFF when the user taps the big icon.
  void _toggleListening() async {
    // If permissions were denied, warn the user
    if (!_speechEnabled) {
      setState(() => _statusMessage = 'Microphone permission denied');
      return;
    }

    if (_speechToText.isNotListening) {
      // START LISTENING
      setState(() {
        _isListening = true;
        _statusMessage = 'Listening...';
        _wordsSpoken = ''; // Clear the previous transcript
      });
      // Start capturing audio and sending it to _onSpeechResult
      await _speechToText.listen(onResult: _onSpeechResult);
    } else {
      // STOP LISTENING manually
      await _speechToText.stop();
      setState(() => _isListening = false);
    }
  }

  /// Callback triggered every time the speech engine detects a new word.
  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _wordsSpoken = result.recognizedWords; // Update UI with live transcript
      _statusMessage = 'Heard: "$_wordsSpoken"';
    });

    // When the user stops talking (e.g., pauses for a second), finalResult is true
    if (result.finalResult) {
      setState(() => _isListening = false);
      _processCommand(
        _wordsSpoken,
      ); // Send the complete sentence to our NLP engine
    }
  }

  // ═══════════════════════════════════════════
  // ADVANCED NLP (Natural Language Processing) ENGINE
  // ═══════════════════════════════════════════

  /// Takes a raw sentence from the user, cleans it up, extracts the intent,
  /// finds the matching device, and triggers the hardware.
  Future<void> _processCommand(String command) async {
    setState(() => _statusMessage = 'Analyzing command...');

    // 1. TEXT NORMALIZATION
    // Voice engines often misunderstand numbers ("set to two" vs "set to 2").
    // We clean the text to ensure numbers are strictly digits.
    String text = command.toLowerCase().trim();
    text = text.replaceAll(' to ', ' 2 ');
    text = text.replaceAll(' too ', ' 2 ');
    text = text.replaceAll(' two ', ' 2 ');
    text = text.replaceAll(' one ', ' 1 ');
    text = text.replaceAll(' three ', ' 3 ');
    text = text.replaceAll(' four ', ' 4 ');
    text = text.replaceAll(' five ', ' 5 ');

    // 2. INTENT DETECTION (What does the user want to do?)
    bool turnOn =
        text.contains('turn on') ||
        text.contains('switch on') ||
        text.contains('start') ||
        text.contains(' on');
    bool turnOff =
        text.contains('turn off') ||
        text.contains('switch off') ||
        text.contains('stop') ||
        text.contains(' off');
    bool isTempOrSpeedCommand =
        text.contains('set') ||
        text.contains('temperature') ||
        text.contains('ac') ||
        text.contains('speed');

    // If no known action was found, abort early.
    if (!turnOn && !turnOff && !isTempOrSpeedCommand) {
      _showStatus(
        'Command not clear. Please say Turn On, Turn Off, Set Temperature, or Set Speed.',
      );
      return;
    }

    // 3. FETCH LIVE STATE
    final allDevices = ref.read(devicesProvider);
    final allRooms = ref.read(roomsProvider);

    // 4. CONTEXT DETECTION (Did they mention a specific room?)
    // E.g., "Turn on the fan in the Bedroom"
    Room? mentionedRoom;
    for (var room in allRooms) {
      if (text.contains(room.name.toLowerCase())) {
        mentionedRoom = room;
        break; // Found the room!
      }
    }

    // Catch errors: They said "room" but we couldn't match the name
    if (text.contains('room') && mentionedRoom == null) {
      _showStatus('Room not found. Please check if the room exists.');
      return;
    }

    // 5. DEVICE MATCHER (Which physical device are they talking to?)
    List<Device> possibleDevices = [];
    for (var device in allDevices) {
      if (text.contains(device.name.toLowerCase())) {
        if (mentionedRoom != null) {
          // Strict Match: They specified a room, so ONLY match devices in that room.
          if (device.roomId == mentionedRoom.id) {
            possibleDevices.add(device);
          }
        } else {
          // Broad Match: They just said a device name, match globally.
          possibleDevices.add(device);
        }
      }
    }

    // No matching device names found in the transcript
    if (possibleDevices.isEmpty) {
      _showStatus(
        'Could not find any device matching your command.\nPlease check the exact device name.',
      );
      return;
    }

    // AMBIGUITY CHECK
    // If they said "Turn on the Fan" but they have a Fan in the Kitchen AND Bedroom.
    if (possibleDevices.length > 1 && mentionedRoom == null) {
      _showStatus(
        'Multiple devices found. Please specify the room (e.g., Fan in Bedroom).',
      );
      return;
    }

    // We successfully narrowed it down to EXACTLY ONE device.
    Device targetDevice = possibleDevices.first;

    // 6. FAN SPEED EXECUTION (REGEX PARSING)
    // Looking for patterns like "Speed 3" or "Set 3"
    if (text.contains('speed') || targetDevice.type == DeviceType.fan) {
      final RegExp speedRegex = RegExp(
        r'speed\s*([0-5])|([0-5])\s*speed|set\s*([0-5])',
      );
      final match = speedRegex.firstMatch(text);

      if (match != null) {
        String? speedStr = match.group(1) ?? match.group(2) ?? match.group(3);
        if (speedStr != null) {
          int speed = int.parse(speedStr);
          await ref
              .read(devicesProvider.notifier)
              .setFanSpeed(targetDevice, speed, method: 'voice');
          _showStatus('Success: ${targetDevice.name} speed set to $speed');
          _giveVoiceFeedback("${targetDevice.name} speed set to $speed");
          return;
        }
      }
    }

    // 7. AC TEMPERATURE EXECUTION (REGEX PARSING)
    // Looking for patterns like "16" up to "32"
    if (targetDevice.type == DeviceType.ac ||
        text.contains('ac') ||
        text.contains('temperature')) {
      final RegExp tempRegex = RegExp(r'\b(1[6-9]|2[0-9]|3[0-2])\b');
      final match = tempRegex.firstMatch(text);

      if (match != null) {
        int temp = int.parse(match.group(0)!); // Extract the two-digit number
        await ref
            .read(devicesProvider.notifier)
            .setACTemperature(targetDevice, temp, method: 'voice');
        await ref
            .read(devicesProvider.notifier)
            .turnOn(
              targetDevice.id,
              method: 'voice',
            ); // Auto-turn ON the AC when setting temp

        _showStatus('Success: ${targetDevice.name} set to $temp degrees');
        _giveVoiceFeedback("${targetDevice.name} set to $temp degrees");
        return;
      }
    }

    // 8. STANDARD ON/OFF EXECUTION
    if (turnOn) {
      await ref
          .read(devicesProvider.notifier)
          .turnOn(targetDevice.id, method: 'voice');
      _showStatus('Success: ${targetDevice.name} turned ON');
      _giveVoiceFeedback("${targetDevice.name} turned on");
    } else if (turnOff) {
      await ref
          .read(devicesProvider.notifier)
          .turnOff(targetDevice.id, method: 'voice');
      _showStatus('Success: ${targetDevice.name} turned OFF');
      _giveVoiceFeedback("${targetDevice.name} turned off");
    }
  }

  // --- Utility Helpers ---

  /// Updates the screen message and automatically clears it after 4 seconds
  void _showStatus(String msg) {
    if (!mounted) return;
    setState(() => _statusMessage = msg);

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _statusMessage = 'Tap mic and give command');
    });
  }

  /// Triggers the TTS (Text-to-Speech) engine to talk back to the user
  void _giveVoiceFeedback(String textToSpeak) {
    ref.read(ttsServiceProvider).speak(textToSpeak);
  }

  // ═══════════════════════════════════════════
  // UI BUILD METHOD
  // ═══════════════════════════════════════════
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
        title: const Text(
          'Voice Control',
          style: TextStyle(color: Colors.white),
        ),
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
                    // --- THE MICROPHONE BUTTON ---
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
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.5),
                                  Colors.transparent,
                                ],
                                // The glowing effect expands when listening is true
                                stops: [
                                  0.3,
                                  0.6 +
                                      (_isListening
                                          ? _pulseController.value * 0.4
                                          : 0.0),
                                  1.0,
                                ],
                              ),
                            ),
                            child: Center(
                              child: Icon(
                                _isListening ? Icons.mic : Icons.mic_none,
                                size: 80,
                                color: Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),

            // --- STATUS / TRANSCRIPT DISPLAY ---
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

            // --- AUDIO VISUALIZER BARS ---
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(30, (index) {
                // Animate bars up and down based on the pulse controller
                final height =
                    _isListening
                        ? (10.0 + (index % 5) * 10.0 * _pulseController.value)
                        : 4.0;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 4,
                  height: height,
                  decoration: BoxDecoration(
                    color:
                        index % 2 == 0
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.secondary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
