// providers/accessibility_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

// Ye provider state save karega ke TTS on hai ya off
final voiceFeedbackProvider = StateProvider<bool>((ref) => false);

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
    await flutterTts.setSpeechRate(0.5); // Awaaz ki speed
    await flutterTts.setVolume(1.0);
  }

  Future<void> speak(String text) async {
    // Check karega ke settings se voice feedback ON hai ya nahi
    final isEnabled = ref.read(voiceFeedbackProvider);
    if (isEnabled) {
      await flutterTts.speak(text);
    }
  }
}