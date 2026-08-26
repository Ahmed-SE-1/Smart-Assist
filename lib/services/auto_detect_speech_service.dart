import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ═══════════════════════════════════════════
// TUNABLE SETTINGS  ←── ADJUST THRESHOLDS HERE
// ═══════════════════════════════════════════

/// Every number the auto-detect strategy depends on, in one place.
class SpeechDetectConfig {
  SpeechDetectConfig._();

  /// Below this, a transcript from the speech engine is treated as unreliable
  /// and we try the other language.
  ///
  /// IMPORTANT: many Android recognisers do not report a confidence at all and
  /// send `-1` instead (see [SpeechAttempt.hasConfidenceRating]). A missing
  /// rating is NOT treated as a low rating — otherwise every single command
  /// would trigger a second listen, which is the opposite of what we want.
  static const double minSttConfidence = 0.5;

  /// Below this NLP confidence, attempt 1 is not trusted and we listen again in
  /// the other language. This is the main decision point, because the NLP
  /// backend is a far better judge of "was that really Urdu?" than the raw STT
  /// confidence is.
  static const double minIntentConfidence = 0.5;

  /// Below this, a transcript is considered garbage rather than merely
  /// uncertain. If BOTH attempts land here we give up instead of acting.
  static const double minUsableIntentConfidence = 0.25;

  /// Absolute backstop so a wedged platform recogniser can never leave the
  /// caller waiting forever. Normal completion happens via the result / status /
  /// error callbacks long before this fires.
  static const Duration listenBackstop = Duration(seconds: 40);

  /// Ceiling on every one-shot platform call made during setup.
  ///
  /// This is not paranoia: `speech_to_text` 7.3.0's Android `locales()` leaves
  /// its method-channel result unset when `checkRecognitionSupport` errors, or
  /// when on-device recognition is unavailable on API 33+. An unset result means
  /// the Dart future NEVER completes, which would hang setup — and therefore the
  /// mic button — permanently. Everything in setup is optional, so timing out
  /// and carrying on is always better than waiting.
  static const Duration platformCallTimeout = Duration(seconds: 5);

  /// Ceiling on the system permission dialog. Long enough that a real user
  /// reading the prompt is never cut off, short enough that a prompt which never
  /// appeared cannot wedge the mic button for the rest of the session. On expiry
  /// we report [SpeechInitStatus.micDenied], which offers a retry — and the retry
  /// re-reads the real status, so a late answer still gets picked up.
  static const Duration permissionPromptTimeout = Duration(seconds: 60);

  /// Grace period after the engine reports "stopped", giving a final result that
  /// is still in flight a chance to arrive before we settle for partials.
  static const Duration finalResultGrace = Duration(milliseconds: 450);

  /// English locales in order of preference.
  static const List<String> englishPreference = ['en-us', 'en-gb'];

  /// Urdu locales in order of preference.
  static const List<String> urduPreference = ['ur-pk', 'ur-in'];

  /// Prefix of the per-user SharedPreferences key that remembers which language
  /// worked last time.
  static const String prefsKeyPrefix = 'last_speech_locale_';

  /// Shown when neither language produced anything usable.
  static const String notCaughtMessage =
      "Sorry, I didn't catch that, please try again";
}

/// Sentinel used by the plugin when the platform gives no confidence value.
const double _confidenceUnavailable = -1.0;

// ═══════════════════════════════════════════
// WHY SETUP FAILED
// ═══════════════════════════════════════════

/// `SpeechToText.initialize()` returns a bare `false` whether the microphone was
/// refused or the device simply has no speech recogniser installed. Those need
/// very different messages — and very different buttons — so we check the
/// microphone permission ourselves first and report the real cause.
enum SpeechInitStatus {
  /// Not attempted yet.
  notStarted,

  /// Microphone granted and a recogniser is present.
  ready,

  /// The user declined the microphone, but we may ask again.
  micDenied,

  /// The user blocked the microphone for good — only app settings can undo it.
  micPermanentlyDenied,

  /// Microphone is fine, but this device has no speech recognition engine.
  /// Common on bare emulators with no Google app installed.
  recognizerUnavailable;

  bool get isReady => this == SpeechInitStatus.ready;

  /// True when sending the user to the system settings page is the only fix.
  bool get needsAppSettings => this == SpeechInitStatus.micPermanentlyDenied;

  /// True when simply asking again can work.
  bool get canRetry =>
      this == SpeechInitStatus.micDenied ||
      this == SpeechInitStatus.recognizerUnavailable;

  /// A message safe to show the user, or null when everything is fine.
  String? get message {
    switch (this) {
      case SpeechInitStatus.notStarted:
      case SpeechInitStatus.ready:
        return null;
      case SpeechInitStatus.micDenied:
        return 'Voice control needs the microphone. Tap "Allow microphone" '
            'and accept the permission prompt.';
      case SpeechInitStatus.micPermanentlyDenied:
        return 'The microphone is blocked for this app. Open Settings → '
            'Permissions → Microphone and allow it, then come back.';
      case SpeechInitStatus.recognizerUnavailable:
        return 'This device has no speech recognition engine available. On '
            'Android, install/enable the Google app and set it as the '
            'assist / voice input service, then try again.';
    }
  }
}

// ═══════════════════════════════════════════
// WHAT THIS DEVICE CAN RECOGNISE
// ═══════════════════════════════════════════

/// The English / Urdu locales actually installed on this device, resolved once
/// at initialisation from `SpeechToText.locales()`.
class SpeechLocaleSupport {
  /// e.g. `en_US`. Null when no English recogniser is installed.
  final String? englishLocaleId;

  /// e.g. `ur_PK`. Null when no Urdu recogniser is installed.
  final String? urduLocaleId;

  /// How many locales the device reported in total (diagnostics only).
  final int totalLocales;

  /// True when the device would not tell us which languages it has — a broken
  /// or timed-out `locales()` call, or an empty list.
  ///
  /// This must NEVER disable voice control. Listening with no explicit locale is
  /// exactly what the app did before auto-detection existed, and it works fine;
  /// we simply lose the ability to try a second language.
  final bool discoveryFailed;

  const SpeechLocaleSupport({
    this.englishLocaleId,
    this.urduLocaleId,
    this.totalLocales = 0,
    this.discoveryFailed = false,
  });

  /// The device wouldn't list its languages, so fall back to its default.
  const SpeechLocaleSupport.unknown() : this(discoveryFailed: true);

  bool get hasEnglish => englishLocaleId != null;
  bool get hasUrdu => urduLocaleId != null;

  /// True when we can actually run the two-attempt strategy.
  bool get isBilingual => hasEnglish && hasUrdu;

  /// True when we can listen at all. Includes [discoveryFailed], because the
  /// device's own default locale still works.
  bool get isUsable => hasEnglish || hasUrdu || discoveryFailed;

  /// Is [localeId] one of the two languages we support?
  bool supports(String localeId) =>
      localeId == englishLocaleId || localeId == urduLocaleId;

  /// A message worth showing the user once, or null when everything is fine.
  ///
  /// Missing Urdu is deliberately a *notice*, not a failure: English keeps
  /// working normally.
  String? get warning {
    // We don't know what's installed, so we have nothing truthful to report.
    // Voice still works on the device default — logged, not shown.
    if (discoveryFailed) return null;
    if (!isUsable) {
      return 'This device has no speech recognition languages installed, so '
          'voice commands are unavailable.';
    }
    if (!hasUrdu) {
      return 'Urdu speech recognition is not available on this device, so only '
          'English commands will be recognised. You can add Urdu in your '
          "phone's voice input / language settings.";
    }
    if (!hasEnglish) {
      return 'English speech recognition is not available on this device, so '
          'only Urdu commands will be recognised.';
    }
    return null;
  }

  @override
  String toString() => discoveryFailed
      ? 'SpeechLocaleSupport(discovery failed — using device default locale)'
      : 'SpeechLocaleSupport(english: $englishLocaleId, urdu: $urduLocaleId, '
          'of $totalLocales locales)';
}

// ═══════════════════════════════════════════
// ONE LISTEN ATTEMPT
// ═══════════════════════════════════════════

/// The outcome of a single `listen()` pass in one specific language.
class SpeechAttempt {
  /// What the engine heard. Empty when it heard nothing usable.
  final String transcript;

  /// The locale this attempt ran in, or null when we let the device pick.
  final String? localeId;

  /// 0..1, or `-1` when the platform did not supply a rating.
  final double confidence;

  /// Set when the recogniser reported an error (no match, timeout, no mic...).
  final String? errorMsg;

  const SpeechAttempt({
    required this.transcript,
    required this.localeId,
    this.confidence = _confidenceUnavailable,
    this.errorMsg,
  });

  factory SpeechAttempt.empty(String? localeId) =>
      SpeechAttempt(transcript: '', localeId: localeId);

  factory SpeechAttempt.error(String? localeId, String message) =>
      SpeechAttempt(transcript: '', localeId: localeId, errorMsg: message);

  bool get hasText => transcript.isNotEmpty;

  /// False on the many devices that never report a confidence score.
  bool get hasConfidenceRating => confidence >= 0;

  /// Does the *speech engine* consider this a solid transcript?
  ///
  /// A missing rating counts as "good enough" on purpose — see
  /// [SpeechDetectConfig.minSttConfidence].
  bool get looksReliable =>
      hasText &&
      (!hasConfidenceRating ||
          confidence >= SpeechDetectConfig.minSttConfidence);

  @override
  String toString() => 'SpeechAttempt($localeId, "$transcript", '
      'confidence: ${hasConfidenceRating ? confidence.toStringAsFixed(2) : 'n/a'}'
      '${errorMsg != null ? ', error: $errorMsg' : ''})';
}

// ═══════════════════════════════════════════
// SCORING (INJECTED BY THE CALLER)
// ═══════════════════════════════════════════

/// How well a transcript scored, plus whatever the caller wants to carry back.
///
/// [payload] lets the caller hand over the object it already built while
/// scoring (an `IntentResult`, say), so the winning transcript never has to be
/// classified twice.
class TranscriptVerdict<T> {
  /// 0..1, higher is better.
  final double score;

  /// The caller's own result object for this transcript.
  final T payload;

  const TranscriptVerdict({required this.score, required this.payload});
}

/// Judges a transcript. Return null when the transcript could not be judged at
/// all (e.g. the network call failed) — the service then stops guessing and
/// hands the transcript back so the caller can surface its own error/retry UI.
///
/// [localeId] is null when the device chose the recognition language itself.
typedef TranscriptScorer<T> = Future<TranscriptVerdict<T>?> Function(
  String transcript,
  String? localeId,
);

// ═══════════════════════════════════════════
// PROGRESS REPORTING (DRIVES THE UI)
// ═══════════════════════════════════════════

enum DetectPhase {
  /// Mic is open for the first language.
  listening,

  /// Mic closed, transcript is being scored.
  thinking,

  /// Mic is re-opening in the *other* language. This is the phase the
  /// "Trying Urdu..." indicator belongs to.
  retryListening,
}

/// A single UI update from the detection flow.
class DetectProgress {
  final DetectPhase phase;

  /// The locale in play, e.g. `ur_PK`. Null when the device picks for us.
  final String? localeId;

  /// Human label for [localeId], e.g. `Urdu`. Empty when unknown.
  final String languageLabel;

  /// 1 or 2.
  final int attempt;

  const DetectProgress({
    required this.phase,
    required this.localeId,
    required this.languageLabel,
    required this.attempt,
  });

  bool get isSecondAttempt => attempt == 2;
}

// ═══════════════════════════════════════════
// FINAL RESULT
// ═══════════════════════════════════════════

/// The end of a full auto-detect run.
class AutoDetectResult<T> {
  /// True when we have a transcript worth acting on.
  final bool success;

  /// The winning transcript. May be non-empty even when [success] is false, so
  /// the caller can show what was heard.
  final String transcript;

  /// The locale that produced [transcript]. Null when the device chose.
  final String? localeId;

  /// Human label for [localeId]. Empty when unknown.
  final String languageLabel;

  /// The scorer's payload for the winning transcript. Null when the transcript
  /// could not be scored — see [judged].
  final T? payload;

  /// False when the scorer could not reach a verdict (network failure). The
  /// caller should fall back to its own "send this text and show errors" path.
  final bool judged;

  /// True when the user tapped the mic again to stop.
  final bool cancelled;

  /// True when a second language was tried.
  final bool usedSecondAttempt;

  /// A message safe to show the user. Non-null on failure.
  final String? message;

  const AutoDetectResult._({
    required this.success,
    this.transcript = '',
    this.localeId,
    this.languageLabel = '',
    this.payload,
    this.judged = true,
    this.cancelled = false,
    this.usedSecondAttempt = false,
    this.message,
  });

  /// A scored, trusted transcript.
  factory AutoDetectResult.success({
    required SpeechAttempt attempt,
    required String languageLabel,
    required T payload,
    required bool usedSecondAttempt,
  }) =>
      AutoDetectResult._(
        success: true,
        transcript: attempt.transcript,
        localeId: attempt.localeId,
        languageLabel: languageLabel,
        payload: payload,
        usedSecondAttempt: usedSecondAttempt,
      );

  /// We heard something but could not score it. The caller owns the next step.
  factory AutoDetectResult.unjudged({
    required SpeechAttempt attempt,
    required String languageLabel,
    required bool usedSecondAttempt,
  }) =>
      AutoDetectResult._(
        success: true,
        transcript: attempt.transcript,
        localeId: attempt.localeId,
        languageLabel: languageLabel,
        judged: false,
        usedSecondAttempt: usedSecondAttempt,
      );

  factory AutoDetectResult.failure({
    required String message,
    String transcript = '',
    bool usedSecondAttempt = false,
  }) =>
      AutoDetectResult._(
        success: false,
        transcript: transcript,
        message: message,
        usedSecondAttempt: usedSecondAttempt,
      );

  factory AutoDetectResult.cancelled() =>
      const AutoDetectResult._(success: false, cancelled: true);
}

// ═══════════════════════════════════════════
// THE SERVICE
// ═══════════════════════════════════════════

/// Wraps [SpeechToText] with automatic English/Urdu detection.
///
/// Native recognisers need a locale *before* they start listening, so real
/// mid-stream language detection is not possible. Instead this service runs a
/// two-attempt strategy:
///
/// 1. Listen in the language that worked last time (persisted per user), or the
///    device's own language on first use.
/// 2. Score that transcript through the caller's [TranscriptScorer].
/// 3. If the score is weak — or nothing was heard — reopen the mic in the OTHER
///    language automatically and score that too.
/// 4. Keep whichever attempt scored higher and remember its locale, so the
///    common case settles into a single listen over time.
///
/// It deliberately knows nothing about HTTP, intents or devices: judging a
/// transcript is injected via [TranscriptScorer], which keeps this class
/// testable and keeps the voice UI out of it.
class AutoDetectSpeechService {
  AutoDetectSpeechService({SpeechToText? speechToText})
      : _speech = speechToText ?? SpeechToText();

  final SpeechToText _speech;

  bool _initialized = false;
  bool _available = false;
  SpeechInitStatus _initStatus = SpeechInitStatus.notStarted;
  SpeechLocaleSupport _support = const SpeechLocaleSupport();
  String? _systemLocaleId;

  /// The single in-flight [initialize] call, shared by every caller.
  ///
  /// Without this, tapping the mic repeatedly while setup is still running fires
  /// a fresh permission request and a fresh `locales()` probe per tap. Android
  /// delivers only one permission result, so the extra calls would never
  /// complete and every tap would silently await forever.
  Future<bool>? _initInFlight;

  /// Set when the user asks us to stop mid-flow, so the two-attempt loop bails
  /// out instead of treating the cancelled attempt as a failed one.
  bool _aborted = false;

  // In-flight listen bookkeeping.
  Completer<SpeechAttempt>? _pending;
  String? _pendingLocale;
  SpeechAttempt? _pendingBest;

  /// True while we are tearing down a previous listen. Engine callbacks that
  /// arrive during this window belong to the OLD attempt, so ignoring them stops
  /// a stale `notListening` from settling the next attempt as empty.
  bool _ignoreEngineEvents = false;

  /// Did the microphone initialise (permissions granted, engine present)?
  bool get isAvailable => _available;

  /// Why setup failed, so the UI can offer the right fix.
  SpeechInitStatus get initStatus => _initStatus;

  /// Is the mic currently open?
  bool get isListening => _speech.isListening;

  /// Which languages this device can recognise.
  SpeechLocaleSupport get localeSupport => _support;

  // ── Setup ────────────────────────────────

  /// Asks for microphone permission, starts the engine, then discovers which
  /// English / Urdu locales exist on this device.
  ///
  /// Safe to call more than once, and safe to call again while a previous call is
  /// still running — concurrent callers share one attempt. A successful init is
  /// cached; a failed one is retried, so a "try again" button can simply call
  /// this.
  ///
  /// Guaranteed to complete: every platform call it makes is bounded by
  /// [SpeechDetectConfig.platformCallTimeout].
  ///
  /// Check [initStatus] when this returns false to find out why.
  Future<bool> initialize() {
    if (_initialized && _available) return Future.value(true);
    return _initInFlight ??=
        _runInitialize().whenComplete(() => _initInFlight = null);
  }

  Future<bool> _runInitialize() async {
    // Ask for the microphone ourselves FIRST, so we can tell "user refused"
    // apart from "no recogniser on this device" — the plugin collapses both into
    // the same `false`. A definitive refusal stops here; anything less certain
    // falls through to the plugin's own request, which is what shipped before.
    final permission = await _ensureMicPermission();
    if (permission != SpeechInitStatus.ready) {
      _initStatus = permission;
      _available = false;
      debugPrint('AutoDetectSpeech: mic permission → $permission');
      return false;
    }

    try {
      _available = await _speech
          .initialize(
            onError: _handleError,
            onStatus: _handleStatus,
            debugLogging: kDebugMode,
          )
          .timeout(SpeechDetectConfig.platformCallTimeout);
    } catch (e) {
      debugPrint('AutoDetectSpeech: initialize() failed — $e');
      _available = false;
    }

    if (!_available) {
      // Microphone is granted, so the engine itself is what's missing.
      _initStatus = SpeechInitStatus.recognizerUnavailable;
      debugPrint('AutoDetectSpeech: no speech recogniser available');
      return false;
    }

    // Locale discovery is a NICE-TO-HAVE. It decides whether we can try a second
    // language — it must never decide whether the mic opens at all.
    _support = await _discoverLocales();
    _initialized = true;
    _initStatus = SpeechInitStatus.ready;
    debugPrint('AutoDetectSpeech: $_support (system: $_systemLocaleId)');
    return true;
  }

  /// Requests `RECORD_AUDIO` and translates the outcome into a
  /// [SpeechInitStatus] the UI can act on.
  ///
  /// Deliberately optimistic: this check exists to produce a *better error
  /// message*, not to become a new way for setup to fail. An unsupported platform
  /// or a broken check reports [ready] and lets the plugin's own permission
  /// handling take over, exactly as it did before this check existed.
  Future<SpeechInitStatus> _ensureMicPermission() async {
    try {
      var status = await Permission.microphone.status
          .timeout(SpeechDetectConfig.platformCallTimeout);

      if (status.isGranted || status.isLimited) return SpeechInitStatus.ready;
      if (status.isPermanentlyDenied) {
        return SpeechInitStatus.micPermanentlyDenied;
      }

      // First ask, or the user tapped "Deny" once without blocking us. Bounded
      // generously: the dialog should wait for the user, but not forever if it
      // never actually appeared.
      try {
        status = await Permission.microphone
            .request()
            .timeout(SpeechDetectConfig.permissionPromptTimeout);
      } on TimeoutException {
        debugPrint('AutoDetectSpeech: permission prompt never answered');
        return SpeechInitStatus.micDenied;
      }

      if (status.isGranted || status.isLimited) return SpeechInitStatus.ready;
      if (status.isPermanentlyDenied) {
        return SpeechInitStatus.micPermanentlyDenied;
      }
      return SpeechInitStatus.micDenied;
    } catch (e) {
      // permission_handler has no implementation for this platform (e.g.
      // Windows desktop), or the check wedged. Let the plugin decide instead of
      // blocking the user here.
      debugPrint('AutoDetectSpeech: permission check unavailable — $e');
      return SpeechInitStatus.ready;
    }
  }

  /// Opens the system settings page for this app, for the
  /// [SpeechInitStatus.micPermanentlyDenied] case.
  Future<bool> openSystemSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('AutoDetectSpeech: could not open app settings — $e');
      return false;
    }
  }

  /// Works out which of English / Urdu this device can recognise.
  ///
  /// Returns [SpeechLocaleSupport.unknown] rather than throwing or hanging when
  /// the device won't say. `locales()` is genuinely unreliable: on API 33+ the
  /// Android plugin leaves its method-channel result unset if
  /// `checkRecognitionSupport` errors or on-device recognition is unavailable,
  /// so the future never completes. The timeout is what keeps the mic button
  /// alive on those devices.
  Future<SpeechLocaleSupport> _discoverLocales() async {
    // The system locale comes from the platform directly — `systemLocale()`
    // would re-enter the same unreliable `locales()` call.
    _systemLocaleId = _deviceLocaleId();

    var locales = <LocaleName>[];
    try {
      locales = await _speech
          .locales()
          .timeout(SpeechDetectConfig.platformCallTimeout);
    } catch (e) {
      debugPrint(
        'AutoDetectSpeech: locales() did not answer ($e) — falling back to the '
        "device's default recognition language",
      );
      return const SpeechLocaleSupport.unknown();
    }

    if (locales.isEmpty) {
      debugPrint(
        'AutoDetectSpeech: device listed no recognition languages — falling '
        "back to the device's default",
      );
      return const SpeechLocaleSupport.unknown();
    }

    final support = SpeechLocaleSupport(
      englishLocaleId:
          _pickLocale(locales, SpeechDetectConfig.englishPreference, 'en'),
      urduLocaleId:
          _pickLocale(locales, SpeechDetectConfig.urduPreference, 'ur'),
      totalLocales: locales.length,
    );

    // Neither language present, but the recogniser clearly works. Use its
    // default rather than refusing to listen.
    if (!support.hasEnglish && !support.hasUrdu) {
      debugPrint(
        'AutoDetectSpeech: neither English nor Urdu among ${locales.length} '
        "locales — falling back to the device's default",
      );
      return const SpeechLocaleSupport.unknown();
    }

    return support;
  }

  /// The device's own language, e.g. `en_US`, read without a platform channel.
  String? _deviceLocaleId() {
    try {
      return Platform.localeName;
    } catch (e) {
      debugPrint('AutoDetectSpeech: could not read device locale — $e');
      return null;
    }
  }

  /// Finds the best available locale for a language: exact preferred matches
  /// first (`en-US`, then `en-GB`), then any locale of that language.
  String? _pickLocale(
    List<LocaleName> locales,
    List<String> preferred,
    String languagePrefix,
  ) {
    for (final want in preferred) {
      for (final locale in locales) {
        if (_normalizeId(locale.localeId) == want) return locale.localeId;
      }
    }
    for (final locale in locales) {
      if (_normalizeId(locale.localeId).startsWith(languagePrefix)) {
        return locale.localeId;
      }
    }
    return null;
  }

  /// Android reports `en_US`, iOS reports `en-US`. Compare them the same way.
  String _normalizeId(String localeId) =>
      localeId.trim().replaceAll('_', '-').toLowerCase();

  /// `ur_PK` → `Urdu`. Empty for an unknown or absent locale, which the UI reads
  /// as "don't name the language".
  String languageLabelFor(String? localeId) {
    if (localeId == null || localeId.isEmpty) return '';
    final id = _normalizeId(localeId);
    if (id.startsWith('ur')) return 'Urdu';
    if (id.startsWith('en')) return 'English';
    return localeId;
  }

  // ── Remembering the user's usual language ─

  String _prefsKey(String userScope) =>
      '${SpeechDetectConfig.prefsKeyPrefix}$userScope';

  /// The locale that last produced a good command for this user, if any.
  Future<String?> loadPreferredLocale(String userScope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey(userScope));
      return (saved == null || saved.isEmpty) ? null : saved;
    } catch (e) {
      debugPrint('AutoDetectSpeech: could not read saved locale — $e');
      return null;
    }
  }

  /// Remembers [localeId] so it is tried first next time. A null locale means we
  /// let the device choose, so there is nothing worth remembering.
  Future<void> savePreferredLocale(String userScope, String? localeId) async {
    if (localeId == null || localeId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey(userScope), localeId);
    } catch (e) {
      debugPrint('AutoDetectSpeech: could not save locale — $e');
    }
  }

  /// Which language to try first: the remembered one, else the device's own
  /// language if we recognise it, else whatever is installed.
  ///
  /// Null means "let the recogniser use its own default" — the behaviour this
  /// screen had before auto-detection existed. That happens when the device
  /// refused to list its languages.
  Future<String?> _resolveFirstLocale(String userScope) async {
    if (_support.discoveryFailed) return null;

    final saved = await loadPreferredLocale(userScope);
    if (saved != null && _support.supports(saved)) return saved;

    final system = _systemLocaleId;
    if (system != null) {
      final id = _normalizeId(system);
      if (id.startsWith('ur') && _support.hasUrdu) return _support.urduLocaleId;
      if (id.startsWith('en') && _support.hasEnglish) {
        return _support.englishLocaleId;
      }
    }

    return _support.englishLocaleId ?? _support.urduLocaleId;
  }

  /// The language we have not tried yet, or null when there is no second one to
  /// try (only one installed, or we never learned what is installed).
  String? _otherLocale(String? localeId) {
    if (!_support.isBilingual) return null;
    return localeId == _support.urduLocaleId
        ? _support.englishLocaleId
        : _support.urduLocaleId;
  }

  // ── The two-attempt flow ─────────────────

  /// Listens, auto-detecting English vs Urdu, and returns the best transcript.
  ///
  /// [userScope] scopes the remembered locale to one user (pass the user id).
  /// [scorer] judges each transcript — usually by calling the NLP backend.
  /// [onProgress] is awaited before the next step, so the caller can pace its
  /// own UI or spoken prompt before the mic reopens.
  /// [onPartial] streams live words for the transcript display.
  Future<AutoDetectResult<T>> listenAndDetect<T>({
    required String userScope,
    required TranscriptScorer<T> scorer,
    Future<void> Function(DetectProgress progress)? onProgress,
    void Function(String partialTranscript)? onPartial,
  }) async {
    _aborted = false;

    if (!await initialize()) {
      return AutoDetectResult.failure(
        message: _initStatus.message ??
            'Voice control is not available on this device.',
      );
    }
    if (!_support.isUsable) {
      return AutoDetectResult.failure(
        message: _support.warning ?? SpeechDetectConfig.notCaughtMessage,
      );
    }

    // Null means "let the recogniser pick its own language" — used when the
    // device would not tell us what it has installed. There is no second
    // language to try in that case, but listening still works.
    final firstLocale = await _resolveFirstLocale(userScope);
    final secondLocale = _otherLocale(firstLocale);

    // ── ATTEMPT 1 ──
    await onProgress?.call(
      DetectProgress(
        phase: DetectPhase.listening,
        localeId: firstLocale,
        languageLabel: languageLabelFor(firstLocale),
        attempt: 1,
      ),
    );
    if (_aborted) return AutoDetectResult.cancelled();

    final first = await _listenOnce(localeId: firstLocale, onPartial: onPartial);
    if (_aborted) return AutoDetectResult.cancelled();
    debugPrint('AutoDetectSpeech attempt 1: $first');

    TranscriptVerdict<T>? firstVerdict;

    /// Attempt 1 has not been sent to the scorer yet. Tracked separately from
    /// `firstVerdict == null`, which also means "the scorer failed".
    var firstScored = false;

    // Only score audio the engine itself rates as usable. A MISSING rating
    // (-1, common on Android) counts as usable — see [minSttConfidence] — so a
    // device that never reports confidence does not double-listen every time.
    if (first.looksReliable) {
      await onProgress?.call(
        DetectProgress(
          phase: DetectPhase.thinking,
          localeId: firstLocale,
          languageLabel: languageLabelFor(firstLocale),
          attempt: 1,
        ),
      );
      if (_aborted) return AutoDetectResult.cancelled();

      firstVerdict = await scorer(first.transcript, firstLocale);
      firstScored = true;
      if (_aborted) return AutoDetectResult.cancelled();

      // Could not judge (network down). Don't burn a second listen on what is
      // not a language problem — hand it back and let the caller show its
      // own error/retry dialog.
      if (firstVerdict == null) {
        return AutoDetectResult.unjudged(
          attempt: first,
          languageLabel: languageLabelFor(firstLocale),
          usedSecondAttempt: false,
        );
      }

      // Good enough → done in one listen. This is the common case once the
      // remembered locale has settled on the user's usual language.
      if (firstVerdict.score >= SpeechDetectConfig.minIntentConfidence) {
        await savePreferredLocale(userScope, firstLocale);
        return AutoDetectResult.success(
          attempt: first,
          languageLabel: languageLabelFor(firstLocale),
          payload: firstVerdict.payload,
          usedSecondAttempt: false,
        );
      }
    }

    // Only one language installed — nothing to fall back to, so score whatever
    // we heard (even if the engine rated it poorly) and take it or give up.
    if (secondLocale == null) {
      if (!firstScored && first.hasText) {
        firstVerdict = await scorer(first.transcript, firstLocale);
        firstScored = true;
        if (_aborted) return AutoDetectResult.cancelled();
        if (firstVerdict == null) {
          return AutoDetectResult.unjudged(
            attempt: first,
            languageLabel: languageLabelFor(firstLocale),
            usedSecondAttempt: false,
          );
        }
      }

      final verdict = firstVerdict;
      if (verdict != null &&
          verdict.score >= SpeechDetectConfig.minUsableIntentConfidence) {
        await savePreferredLocale(userScope, firstLocale);
        return AutoDetectResult.success(
          attempt: first,
          languageLabel: languageLabelFor(firstLocale),
          payload: verdict.payload,
          usedSecondAttempt: false,
        );
      }
      return AutoDetectResult.failure(
        message: SpeechDetectConfig.notCaughtMessage,
        transcript: first.transcript,
      );
    }

    // ── ATTEMPT 2, in the other language ──
    await onProgress?.call(
      DetectProgress(
        phase: DetectPhase.retryListening,
        localeId: secondLocale,
        languageLabel: languageLabelFor(secondLocale),
        attempt: 2,
      ),
    );
    if (_aborted) return AutoDetectResult.cancelled();

    final second =
        await _listenOnce(localeId: secondLocale, onPartial: onPartial);
    if (_aborted) return AutoDetectResult.cancelled();
    debugPrint('AutoDetectSpeech attempt 2: $second');

    TranscriptVerdict<T>? secondVerdict;
    if (second.looksReliable) {
      await onProgress?.call(
        DetectProgress(
          phase: DetectPhase.thinking,
          localeId: secondLocale,
          languageLabel: languageLabelFor(secondLocale),
          attempt: 2,
        ),
      );
      if (_aborted) return AutoDetectResult.cancelled();

      secondVerdict = await scorer(second.transcript, secondLocale);
      if (_aborted) return AutoDetectResult.cancelled();

      if (secondVerdict == null) {
        return AutoDetectResult.unjudged(
          attempt: second,
          languageLabel: languageLabelFor(secondLocale),
          usedSecondAttempt: true,
        );
      }
    }

    // Attempt 2 produced nothing usable. If attempt 1 was skipped purely on a
    // low engine confidence, give its text a hearing now rather than throwing
    // away a transcript we already have — the NLP backend may well understand
    // it, and the caller still gets a confirmation prompt for weak guesses.
    if ((secondVerdict?.score ?? -1) <
            SpeechDetectConfig.minUsableIntentConfidence &&
        !firstScored &&
        first.hasText) {
      firstVerdict = await scorer(first.transcript, firstLocale);
      firstScored = true;
      if (_aborted) return AutoDetectResult.cancelled();
      if (firstVerdict == null) {
        return AutoDetectResult.unjudged(
          attempt: first,
          languageLabel: languageLabelFor(firstLocale),
          usedSecondAttempt: true,
        );
      }
    }

    // ── Arbitrate: keep the better-scoring language ──
    final firstScore = firstVerdict?.score ?? -1;
    final secondScore = secondVerdict?.score ?? -1;

    // Both attempts were empty or garbage → say so instead of acting on noise.
    if (firstScore < SpeechDetectConfig.minUsableIntentConfidence &&
        secondScore < SpeechDetectConfig.minUsableIntentConfidence) {
      return AutoDetectResult.failure(
        message: SpeechDetectConfig.notCaughtMessage,
        transcript: second.hasText ? second.transcript : first.transcript,
        usedSecondAttempt: true,
      );
    }

    // Ties fall back to the raw engine confidence, then to attempt 1.
    final secondWins = secondScore > firstScore ||
        (secondScore == firstScore && second.confidence > first.confidence);

    final winner = secondWins ? second : first;
    final winnerVerdict = (secondWins ? secondVerdict : firstVerdict)!;

    // Remember the winner so it is tried FIRST next time.
    await savePreferredLocale(userScope, winner.localeId);

    return AutoDetectResult.success(
      attempt: winner,
      languageLabel: languageLabelFor(winner.localeId),
      payload: winnerVerdict.payload,
      usedSecondAttempt: true,
    );
  }

  // ── One listen pass ──────────────────────

  /// Opens the mic in [localeId] and completes when the engine produces a final
  /// result, stops, or errors.
  ///
  /// The `listen()` call is intentionally left at the plugin's defaults apart
  /// from `localeId`, so audio capture behaves exactly as it did before
  /// auto-detection was added.
  Future<SpeechAttempt> _listenOnce({
    required String? localeId,
    void Function(String partialTranscript)? onPartial,
  }) async {
    await _stopIfListening();

    final completer = Completer<SpeechAttempt>();
    _pending = completer;
    _pendingLocale = localeId;
    _pendingBest = null;

    try {
      await _speech.listen(
        localeId: localeId,
        onResult: (result) => _handleResult(result, localeId, onPartial),
      );
    } catch (e) {
      debugPrint('AutoDetectSpeech: listen() threw $e');
      _pending = null;
      return SpeechAttempt.error(localeId, '$e');
    }

    return completer.future.timeout(
      SpeechDetectConfig.listenBackstop,
      onTimeout: () {
        debugPrint('AutoDetectSpeech: listen backstop fired for $localeId');
        _pending = null;
        return _pendingBest ?? SpeechAttempt.empty(localeId);
      },
    );
  }

  void _handleResult(
    SpeechRecognitionResult result,
    String? localeId,
    void Function(String partialTranscript)? onPartial,
  ) {
    if (_ignoreEngineEvents) return;

    final attempt = SpeechAttempt(
      transcript: result.recognizedWords.trim(),
      localeId: localeId,
      // `confidence` is -1 when the platform supplies no rating; the getter
      // already guards against an empty alternates list.
      confidence: result.confidence,
    );

    if (attempt.hasText) _pendingBest = attempt;

    if (result.finalResult) {
      _settle(attempt.hasText ? attempt : (_pendingBest ?? attempt));
    } else if (attempt.hasText) {
      onPartial?.call(attempt.transcript);
    }
  }

  void _handleStatus(String status) {
    debugPrint('AutoDetectSpeech status: $status');
    if (_ignoreEngineEvents) return;
    if (status != SpeechToText.notListeningStatus &&
        status != SpeechToText.doneStatus) {
      return;
    }
    // The mic closed. Give a final result that is still in flight a moment to
    // land before we settle for whatever partial text we have.
    final closing = _pending;
    Future.delayed(SpeechDetectConfig.finalResultGrace, () {
      if (closing == null || _pending != closing) return;
      // A fresh listen started in the meantime — this status was stale.
      if (_speech.isListening) return;
      _settle(_pendingBest ?? SpeechAttempt.empty(_pendingLocale));
    });
  }

  void _handleError(SpeechRecognitionError error) {
    debugPrint(
      'AutoDetectSpeech error: ${error.errorMsg} (permanent: ${error.permanent})',
    );
    if (_ignoreEngineEvents) return;
    // `error_no_match` / `error_speech_timeout` are routine "heard nothing"
    // outcomes, so keep any partial text we already had.
    final best = _pendingBest;
    _settle(
      (best != null && best.hasText)
          ? best
          : SpeechAttempt.error(_pendingLocale, error.errorMsg),
    );
  }

  void _settle(SpeechAttempt attempt) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _pending = null;
    pending.complete(attempt);
  }

  /// Closes a previously-open mic and waits for its trailing callbacks to drain,
  /// so they cannot be mistaken for the next attempt's.
  Future<void> _stopIfListening() async {
    if (!_speech.isListening) return;
    _ignoreEngineEvents = true;
    try {
      await _speech.stop();
    } catch (e) {
      debugPrint('AutoDetectSpeech: stop() threw $e');
    }
    await Future.delayed(const Duration(milliseconds: 250));
    _ignoreEngineEvents = false;
  }

  // ── Stopping ─────────────────────────────

  /// Stops the current run because the user asked to. Makes
  /// [listenAndDetect] return [AutoDetectResult.cancelled] instead of rolling
  /// on to the second language.
  Future<void> abort() async {
    _aborted = true;
    await cancel();
  }

  /// Closes the mic and discards any in-flight attempt.
  Future<void> cancel() async {
    _settle(SpeechAttempt.empty(_pendingLocale));
    try {
      await _speech.cancel();
    } catch (e) {
      debugPrint('AutoDetectSpeech: cancel() threw $e');
    }
  }

  /// Call from the owning provider's `onDispose`.
  void dispose() {
    _settle(SpeechAttempt.empty(_pendingLocale));
    _speech.cancel();
  }
}
