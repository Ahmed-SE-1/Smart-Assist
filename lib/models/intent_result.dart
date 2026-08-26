/// The set of intents our custom bilingual (English + Urdu) NLP backend returns.
///
/// [wireName] is the exact string the API sends in its `intent` field. Keeping it
/// on the enum means the raw strings live in exactly one place, so a backend
/// rename only has to be fixed here.
enum VoiceIntent {
  deviceOn('device_on'),
  deviceOff('device_off'),
  increaseValue('increase_value'),
  decreaseValue('decrease_value'),
  deviceOpen('device_open'),
  deviceClose('device_close'),
  statusCheck('status_check'),

  /// Used when the backend sends an intent this build of the app doesn't know.
  unknown('unknown');

  const VoiceIntent(this.wireName);

  final String wireName;

  /// Converts the API's `intent` string into an enum value.
  ///
  /// Never throws — anything unrecognised becomes [VoiceIntent.unknown], so
  /// deploying a newer backend can't crash an older app build.
  static VoiceIntent fromWire(String? raw) {
    if (raw == null) return VoiceIntent.unknown;
    final key = raw.trim().toLowerCase();
    for (final intent in VoiceIntent.values) {
      if (intent.wireName == key) return intent;
    }
    return VoiceIntent.unknown;
  }

  /// Plain-English phrasing used inside the "Did you mean to ...?" dialog.
  String get actionLabel {
    switch (this) {
      case VoiceIntent.deviceOn:
      case VoiceIntent.deviceOpen:
        return 'turn the device ON';
      case VoiceIntent.deviceOff:
      case VoiceIntent.deviceClose:
        return 'turn the device OFF';
      case VoiceIntent.increaseValue:
        return 'increase the speed / temperature';
      case VoiceIntent.decreaseValue:
        return 'decrease the speed / temperature';
      case VoiceIntent.statusCheck:
        return 'check the device status';
      case VoiceIntent.unknown:
        return 'run an unrecognised command';
    }
  }
}

/// A parsed `/predict` response from the NLP backend.
///
/// Mirrors the JSON contract exactly:
/// ```json
/// { "intent": "device_on", "confidence": 0.94,
///   "needs_confirmation": false, "raw_text": "turn on the fan" }
/// ```
class IntentResult {
  /// The raw intent string exactly as the server sent it.
  final String intent;

  /// How sure the model is, clamped to 0.0 - 1.0.
  final double confidence;

  /// When true the model is unsure, so the UI MUST ask the user before acting.
  final bool needsConfirmation;

  /// The text that was classified. Used to work out which device was meant.
  final String rawText;

  const IntentResult({
    required this.intent,
    required this.confidence,
    required this.needsConfirmation,
    required this.rawText,
  });

  /// The [intent] string resolved to a type-safe enum.
  VoiceIntent get type => VoiceIntent.fromWire(intent);

  /// Confidence as a whole number, for display (e.g. `62%`).
  int get confidencePercent => (confidence * 100).round();

  factory IntentResult.fromJson(Map<String, dynamic> json, {String? fallbackText}) {
    // `confidence` may arrive as an int (1) or a double (0.94), so read it as num.
    final rawConfidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;

    // If the server omits `needs_confirmation` we default to TRUE. Asking an
    // unnecessary question is always safer than switching hardware by accident.
    final confirm = json['needs_confirmation'];

    final echoed = (json['raw_text'] as String?)?.trim();

    return IntentResult(
      intent: (json['intent'] as String?)?.trim() ?? VoiceIntent.unknown.wireName,
      confidence: rawConfidence.clamp(0.0, 1.0),
      needsConfirmation: confirm is bool ? confirm : true,
      rawText: (echoed == null || echoed.isEmpty) ? (fallbackText ?? '') : echoed,
    );
  }

  @override
  String toString() =>
      'IntentResult(intent: $intent, confidence: $confidence, '
      'needsConfirmation: $needsConfirmation, rawText: "$rawText")';
}
