import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../models/intent_result.dart';
import '../../../providers/smart_home_provider.dart';
import '../../../providers/accessibility_provider.dart';
import '../../../providers/service_providers.dart';
import '../../../providers/user_provider.dart';
import '../../../services/auto_detect_speech_service.dart';
import '../../../services/nlp_api_service.dart';
import '../../../services/voice_command_mapper.dart';

/// The Voice Control screen allows users to trigger smart home commands
/// by speaking naturally into their microphone.
///
/// The user never picks a language. [AutoDetectSpeechService] captures speech
/// in whichever of English / Urdu worked last time, and if the result scores
/// poorly it automatically reopens the mic in the other language and keeps the
/// better attempt. Scoring is done by our own NLP backend, which understands
/// English, Urdu script and Roman Urdu alike — see [NlpApiService].
class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen>
    with SingleTickerProviderStateMixin {
  // --- Speech Engine Variables ---
  bool _speechEnabled =
      false; // Checks if the user granted microphone permissions

  // --- UI Animation Variables ---
  bool _isListening = false;
  late AnimationController
  _pulseController; // Controls the glowing ring around the microphone
  String _statusMessage = 'Tap mic and give command';

  // --- NLP Backend Variables ---
  /// True while we are waiting on the NLP API or on the hardware. Drives the
  /// loading spinner and blocks a second command from overlapping the first.
  bool _isProcessing = false;

  /// The last finished transcript, kept so the error dialog's "Retry" button can
  /// re-send it without making the user speak the whole command again.
  String _lastTranscript = '';

  // --- Language Auto-Detection Variables ---
  /// The subtle "Trying Urdu..." pill shown while the second listen attempt
  /// runs, so the retry reads as deliberate rather than as a freeze.
  String? _detectBanner;

  /// One-off notice when this device has no Urdu recogniser installed.
  /// English keeps working, so this is informational only.
  String? _localeNotice;

  /// Guards against the mic button starting a second run over the first.
  bool _commandInFlight = false;

  /// Scopes the remembered language to this user, matching the
  /// `shared_house_devices_db_<houseId>` style used elsewhere in the app.
  String get _userScope => ref.read(userProvider)?.id ?? 'default';

  /// Captured in [initState] rather than read on demand: `dispose()` needs it to
  /// stop the microphone, and `ref` may not be touched once the widget is gone.
  late final AutoDetectSpeechService _speechService;

  /// Why the microphone could not start, so we can show the right fix button.
  SpeechInitStatus _initStatus = SpeechInitStatus.notStarted;

  @override
  void initState() {
    super.initState();

    // Grab the service now: dispose() must stop the mic, and by then `ref` is
    // off limits.
    _speechService = ref.read(autoDetectSpeechServiceProvider);

    // Setup the glowing pulse animation for the microphone
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    // Initialize the microphone immediately when the screen opens
    _initSpeech();
  }

  /// Asks for microphone permission, starts the Speech Engine, and checks which
  /// of English / Urdu this device can actually recognise.
  ///
  /// Also called by the "Allow microphone" / "Try again" button, so a refused
  /// permission is recoverable without leaving the screen.
  Future<void> _initSpeech() async {
    final enabled = await _speechService.initialize();
    if (!mounted) return;

    setState(() {
      _speechEnabled = enabled;
      _initStatus = _speechService.initStatus;
      // If Urdu is missing we still let English work normally — just say so.
      _localeNotice =
          enabled ? _speechService.localeSupport.warning : _initStatus.message;
      _statusMessage = enabled
          ? 'Tap mic and give command'
          : (_initStatus.message ?? 'Voice control is unavailable.');
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    // CRITICAL: Stop listening when leaving the screen to save battery.
    _speechService.cancel();
    super.dispose();
  }

  /// Toggles the microphone ON or OFF when the user taps the big icon.
  ///
  /// This must always do *something* visible. A tap that silently returns is
  /// indistinguishable from a broken button, so every early exit below reports
  /// why it stopped.
  void _toggleListening() async {
    // Tapping again mid-run means "stop" — abort so the service does NOT roll
    // on to a second language attempt. Checked first so a stuck run is always
    // cancellable.
    if (_commandInFlight) {
      await _speechService.abort();
      return;
    }

    // A tap during the NLP call would overlap two commands. Say so rather than
    // ignoring the tap.
    if (_isProcessing) {
      _showStatus('Still working on your last command...');
      return;
    }

    // If setup failed, tapping the mic is the natural way to re-ask rather than
    // just repeating the error.
    if (!_speechEnabled) {
      setState(() => _statusMessage = 'Starting the microphone...');
      await _initSpeech();
      if (!mounted || !_speechEnabled) return;
    }

    await _runVoiceCommand();
  }

  // ═══════════════════════════════════════════
  // AUTOMATIC LANGUAGE DETECTION
  // ═══════════════════════════════════════════

  /// Listens with automatic English/Urdu detection, then acts on the result.
  ///
  /// [AutoDetectSpeechService] owns the two-attempt strategy; this method only
  /// reflects its progress in the UI and decides what to do with the winner.
  Future<void> _runVoiceCommand() async {
    _commandInFlight = true;
    setState(() {
      _detectBanner = null;
      _statusMessage = 'Listening...';
    });

    try {
      final result = await _speechService.listenAndDetect<IntentResult>(
        userScope: _userScope,
        scorer: _scoreTranscript,
        onProgress: _onDetectProgress,
        onPartial: (partial) {
          if (!mounted) return;
          setState(() => _statusMessage = 'Heard: "$partial"');
        },
      );

      if (!mounted) return;
      setState(() {
        _isListening = false;
        _isProcessing = false;
        _detectBanner = null;
      });

      if (result.cancelled) {
        _showStatus('Stopped. Tap the mic to try again.');
        return;
      }

      // Both languages came back empty or unintelligible — say so instead of
      // sending garbage to the backend.
      if (!result.success) {
        final spoken = result.message ?? SpeechDetectConfig.notCaughtMessage;

        // If we DID hear words, the problem was the command, not the audio.
        // Saying so is far more useful than a bare "didn't catch that".
        _showStatus(
          result.transcript.isEmpty
              ? spoken
              : '$spoken\n\nI heard: "${result.transcript}"\n'
                  'Try "Turn on the bedroom light" or "بیڈروم کی بتی جلاؤ".',
        );
        _giveVoiceFeedback(spoken);
        return;
      }

      setState(() {
        // The label is empty when the device chose the language for us — don't
        // print "Heard ():".
        _statusMessage = result.languageLabel.isEmpty
            ? 'Heard: "${result.transcript}"'
            : 'Heard (${result.languageLabel}): "${result.transcript}"';
      });

      // The scorer could not reach the backend, so we have text but no intent.
      // Fall through to the normal send-and-retry path, which owns the
      // connection-error dialog.
      if (!result.judged) {
        await _processCommand(result.transcript);
        return;
      }

      _lastTranscript = result.transcript;
      await _handleIntent(result.payload!);
    } catch (e, stack) {
      // Anything unexpected downstream (mapper, dialog, provider) must not leave
      // the spinner up forever — that would look exactly like a dead mic button.
      debugPrint('Voice command failed: $e\n$stack');
      _showStatus('Something went wrong. Tap the mic to try again.');
    } finally {
      _commandInFlight = false;
      // Safety net: whatever happened above, the screen goes back to idle so the
      // next tap works.
      if (mounted) {
        setState(() {
          _isListening = false;
          _isProcessing = false;
          _detectBanner = null;
        });
      }
    }
  }

  /// Judges a transcript by classifying it with the NLP backend.
  ///
  /// The returned score is what decides whether a second language is tried, and
  /// the [IntentResult] rides along as the payload so the winning transcript is
  /// never classified twice. Returning null means "could not judge" (network
  /// failure), which stops the service from wasting a second listen on what is
  /// not a language problem.
  Future<TranscriptVerdict<IntentResult>?> _scoreTranscript(
    String transcript,
    String? localeId,
  ) async {
    final response = await ref.read(nlpApiServiceProvider).predict(transcript);

    if (!response.success) {
      debugPrint('Scoring failed for "$transcript": ${response.message}');
      return null;
    }

    final intent = response.intent!;
    // An unrecognised intent is the strongest hint that we listened in the
    // wrong language, so it scores zero rather than its raw confidence.
    final score =
        intent.type == VoiceIntent.unknown ? 0.0 : intent.confidence;

    debugPrint(
      'Scored "$transcript" ($localeId) → ${intent.intent} @ '
      '${score.toStringAsFixed(2)}',
    );
    return TranscriptVerdict(score: score, payload: intent);
  }

  /// Mirrors the detection phases in the UI. Awaited by the service, so the
  /// spoken retry prompt gets to finish before the mic reopens.
  Future<void> _onDetectProgress(DetectProgress progress) async {
    if (!mounted) return;

    switch (progress.phase) {
      case DetectPhase.listening:
        setState(() {
          _isListening = true;
          _isProcessing = false;
          _detectBanner = null;
          _statusMessage = 'Listening...';
        });

      case DetectPhase.thinking:
        setState(() {
          _isListening = false;
          _isProcessing = true;
          _detectBanner = null;
          _statusMessage = 'Understanding your command...';
        });

      case DetectPhase.retryListening:
        final prompt = 'Trying ${progress.languageLabel} — please repeat';
        setState(() {
          _isListening = true;
          _isProcessing = false;
          _detectBanner = prompt;
          _statusMessage = 'Listening...';
        });

        // Speaks only when the user has voice feedback switched on — TtsService
        // is a no-op otherwise.
        final speakingAloud = ref.read(voiceFeedbackProvider);
        _giveVoiceFeedback(prompt);

        // Let the banner register, and keep the mic closed until the spoken
        // prompt has finished so the recogniser doesn't transcribe our own TTS.
        await Future.delayed(
          Duration(milliseconds: speakingAloud ? 2200 : 700),
        );
    }
  }

  // ═══════════════════════════════════════════
  // NLP BACKEND INTEGRATION
  // ═══════════════════════════════════════════

  /// Sends a finished transcript to our bilingual (English + Urdu) NLP backend,
  /// confirms low-confidence guesses with the user, then triggers the device.
  ///
  /// Audio capture is untouched by this method — [SpeechToText] has already
  /// produced the text by the time we get here.
  Future<void> _processCommand(String command) async {
    final transcript = command.trim();
    if (transcript.isEmpty) {
      _showStatus('I did not catch that. Tap the mic and try again.');
      return;
    }

    _lastTranscript = transcript;

    // Retry loop: on a network failure the user can re-send the SAME transcript
    // from the error dialog, without having to speak the command again.
    while (true) {
      setState(() {
        _isProcessing = true;
        _statusMessage = 'Understanding your command...';
      });

      final response =
          await ref.read(nlpApiServiceProvider).predict(_lastTranscript);

      if (!mounted) return;
      setState(() => _isProcessing = false);

      if (response.success) {
        await _handleIntent(response.intent!);
        return;
      }

      final shouldRetry = await _showApiErrorDialog(response);
      if (!mounted) return;
      if (shouldRetry != true) {
        _showStatus('Command cancelled. Tap the mic to try again.');
        return;
      }
    }
  }

  /// Decides whether an intent can run straight away or needs confirming first.
  Future<void> _handleIntent(IntentResult intent) async {
    debugPrint('NLP intent: $intent');

    if (intent.type == VoiceIntent.unknown) {
      _showStatus(
        'I heard the words but not a known command.\n'
        'Try "Turn on the bedroom light" or "بیڈروم کی بتی جلاؤ".',
      );
      _giveVoiceFeedback('Sorry, I did not understand that command.');
      return;
    }

    // LOW CONFIDENCE → never act silently, always ask first.
    if (intent.needsConfirmation) {
      final confirmed = await _showConfirmationDialog(intent);
      if (!mounted) return;

      if (confirmed != true) {
        _showStatus('Cancelled. Tap the mic to try again.');
        _giveVoiceFeedback('Command cancelled.');
        return;
      }
    }

    await _executeIntent(intent);
  }

  /// Hands the confirmed intent to [VoiceCommandMapper], which resolves the
  /// target device and calls the matching [DevicesNotifier] method.
  Future<void> _executeIntent(IntentResult intent) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Sending command to your device...';
    });

    final mapper = VoiceCommandMapper(
      devices: ref.read(devicesProvider),
      rooms: ref.read(roomsProvider),
      notifier: ref.read(devicesProvider.notifier),
    );

    final outcome = await mapper.execute(intent);

    if (!mounted) return;
    setState(() => _isProcessing = false);

    _showStatus(outcome.success ? 'Success: ${outcome.message}' : outcome.message);
    _giveVoiceFeedback(outcome.speech);
  }

  // ═══════════════════════════════════════════
  // DIALOGS
  // ═══════════════════════════════════════════

  /// Shown when the backend replies with `needs_confirmation: true`.
  /// Returns true only if the user explicitly taps "Yes".
  Future<bool?> _showConfirmationDialog(IntentResult intent) {
    final question = 'Did you mean to ${intent.type.actionLabel}?';
    _giveVoiceFeedback(question);

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.help_outline,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(width: 10),
            const Text(
              'Please confirm',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              question,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'I heard: "${intent.rawText}"',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              'Confidence: ${intent.confidencePercent}%',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }

  /// Shown when the `/predict` call fails. Returns true if the user wants to
  /// resend the same transcript.
  Future<bool?> _showApiErrorDialog(NlpResult response) {
    _giveVoiceFeedback('I could not reach the language server.');

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cloud_off, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text(
              'Connection problem',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              response.message ?? 'Could not understand your command.',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Your command: "$_lastTranscript"',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
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
                      // Never null: a disabled tap target is indistinguishable
                      // from a broken one, so _toggleListening decides what a
                      // tap means (start / stop / "still working") instead.
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
                              // LOADING INDICATOR: replaces the mic icon while
                              // we wait for the NLP backend / hardware.
                              child: _isProcessing
                                  ? const SizedBox(
                                      width: 64,
                                      height: 64,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      _isListening ? Icons.mic : Icons.mic_none,
                                      size: 80,
                                      color: Colors.white,
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 28),

                    // --- LANGUAGE AUTO-DETECT INDICATOR ---
                    // Subtle pill shown only while the SECOND listen attempt is
                    // running, so the extra prompt reads as deliberate rather
                    // than as the app freezing. Keeps its space when hidden so
                    // nothing jumps.
                    SizedBox(
                      height: 36,
                      child: Center(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 250),
                          opacity: _detectBanner == null ? 0.0 : 1.0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.translate,
                                  size: 16,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _detectBanner ?? '',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
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

            // --- SETUP PROBLEM / URDU-UNAVAILABLE NOTICE ---
            // When speech is working this is just an informational note (e.g.
            // "Urdu isn't installed, English still works"). When setup failed it
            // explains why and offers the matching fix.
            if (_localeNotice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _speechEnabled ? Icons.info_outline : Icons.mic_off,
                      size: 16,
                      color: _speechEnabled
                          ? Colors.orangeAccent
                          : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _localeNotice!,
                        style: TextStyle(
                          color: _speechEnabled
                              ? Colors.orangeAccent
                              : Colors.redAccent,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // --- THE FIX BUTTON ---
            // "Allow microphone" re-asks; a permanently blocked mic can only be
            // undone in the system settings, so we send the user there instead.
            if (!_speechEnabled && _initStatus != SpeechInitStatus.notStarted)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  onPressed: _initStatus.needsAppSettings
                      ? () => _speechService.openSystemSettings()
                      : _initSpeech,
                  icon: Icon(
                    _initStatus.needsAppSettings
                        ? Icons.settings
                        : Icons.mic_none,
                    size: 18,
                  ),
                  label: Text(
                    _initStatus.needsAppSettings
                        ? 'Open Settings'
                        : (_initStatus == SpeechInitStatus.recognizerUnavailable
                            ? 'Try again'
                            : 'Allow microphone'),
                  ),
                ),
              ),

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
