// providers/accessibility_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

// Pehle wala TTS On/Off provider
final voiceFeedbackProvider = StateProvider<bool>((ref) => false);

// NAYA: Text screen par show karne ka provider (Subtitles)
final showTextFeedbackProvider = StateProvider<bool>((ref) => true);

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