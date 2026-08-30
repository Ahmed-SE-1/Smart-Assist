import 'package:flutter_tts/flutter_tts.dart';

/// Text-to-speech helper dedicated to Gesture Control accessibility.
///
/// Unlike [TtsService] in accessibility_provider.dart, this always speaks
/// during an active gesture session so blind/disabled users get feedback
/// regardless of the global voice-feedback toggle.
class GestureTtsHelper {
  GestureTtsHelper() {
    _init();
  }

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> _init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    _initialized = true;
  }

  /// Speaks [text] aloud. Queues are cleared first to avoid stale announcements.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_initialized) await _init();
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
