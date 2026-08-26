import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auto_detect_speech_service.dart';
import '../services/mqtt_service.dart';
import '../services/nlp_api_service.dart';

final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  service.connect();
  ref.onDispose(() => service.dispose());
  return service;
});

/// The bilingual (English + Urdu) intent classifier backend.
/// Change the server address in [NlpApiConfig.baseUrl].
final nlpApiServiceProvider = Provider<NlpApiService>((ref) {
  final service = NlpApiService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Speech-to-text with automatic English/Urdu detection.
///
/// Created once and kept alive for the whole app: [SpeechToText] talks to a
/// single platform recogniser, so rebuilding it mid-session would fight with the
/// live microphone. The per-user "remembered language" key is passed in at call
/// time via `userScope` instead of being baked into the provider.
/// Thresholds live in [SpeechDetectConfig].
final autoDetectSpeechServiceProvider = Provider<AutoDetectSpeechService>((ref) {
  final service = AutoDetectSpeechService();
  ref.onDispose(() => service.dispose());
  return service;
});
