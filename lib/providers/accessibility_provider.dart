// providers/accessibility_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:shared_preferences/shared_preferences.dart';

class VoiceFeedbackNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('voiceFeedbackEnabled') ?? false;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voiceFeedbackEnabled', value);
  }
}

class ShowTextFeedbackNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true; // Default to true
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('visualAlertsEnabled') ?? true;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('visualAlertsEnabled', value);
  }
}

final voiceFeedbackProvider = NotifierProvider<VoiceFeedbackNotifier, bool>(VoiceFeedbackNotifier.new);
final showTextFeedbackProvider = NotifierProvider<ShowTextFeedbackNotifier, bool>(ShowTextFeedbackNotifier.new);

// Ye service actual text ko aawaz mein convert karegi
final ttsServiceProvider = Provider<TtsService>((ref) {
  return TtsService(ref);
});

class TtsService {
  final Ref ref;
  final FlutterTts flutterTts = FlutterTts();

  TtsService(this.ref) {
    _initTts();
  }

  void _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
  }

  Future<void> speak(String text) async {
    final isEnabled = ref.read(voiceFeedbackProvider);
    if (isEnabled) {
      await flutterTts.speak(text);
    }
  }
}
