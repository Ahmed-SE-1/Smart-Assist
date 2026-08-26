import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/intent_result.dart';

// ═══════════════════════════════════════════
// API CONFIGURATION  ←── CHANGE THE URL HERE
// ═══════════════════════════════════════════

/// Single place to point the app at the NLP backend.
///
/// Pick the line that matches where you are testing:
///
/// * Android **emulator**            → `http://10.0.2.2:8000`
///   (an emulator's `localhost` is the emulator itself, not your PC)
/// * Real phone on the **same WiFi** → `http://192.168.1.42:8000`
///   (run `ipconfig` on the server machine to get its LAN IP)
/// * Desktop / iOS simulator         → `http://localhost:8000`
/// * Deployed server                 → `https://nlp.your-domain.com`
///
/// NOTE: for a plain `http://` address on Android you also need
/// `android:usesCleartextTraffic="true"` in `AndroidManifest.xml`.
class NlpApiConfig {
  NlpApiConfig._();

  /// The base address of the NLP server. This is the only line you need to edit
  /// when switching between local testing and deployment.
  static const String baseUrl = 'http://192.168.100.76:8000';

  /// The intent-classification endpoint.
  static const String predictPath = '/predict';

  /// How long to wait before giving up on a request.
  static const Duration requestTimeout = Duration(seconds: 8);

  static Uri get predictUri => Uri.parse('$baseUrl$predictPath');
}

// ═══════════════════════════════════════════
// RESULT / ERROR TYPES
// ═══════════════════════════════════════════

/// Why a `/predict` call failed. Lets the UI react differently per cause if
/// it ever needs to (e.g. only offer "Retry" for timeouts).
enum NlpErrorType {
  /// Phone has no route to the server (wrong IP, server not running, no WiFi).
  noConnection,

  /// Server accepted the connection but didn't answer in time.
  timeout,

  /// Server answered with a non-200 status code.
  serverError,

  /// Server answered 200 but the body wasn't the JSON we expect.
  badResponse,

  /// Anything we didn't anticipate.
  unknown,
}

/// A standard response wrapper, following the same `success` + `message` shape
/// as [CommandResult] in `iot_simulation_service.dart`.
///
/// The service never throws — callers always get one of these back.
class NlpResult {
  /// Did we get a usable intent from the server?
  final bool success;

  /// The parsed intent. Non-null exactly when [success] is true.
  final IntentResult? intent;

  /// What went wrong. Non-null exactly when [success] is false.
  final NlpErrorType? errorType;

  /// A message safe to show directly to the user.
  final String? message;

  const NlpResult._({
    required this.success,
    this.intent,
    this.errorType,
    this.message,
  });

  factory NlpResult.success(IntentResult intent) =>
      NlpResult._(success: true, intent: intent);

  factory NlpResult.failure(NlpErrorType type, String message) =>
      NlpResult._(success: false, errorType: type, message: message);
}

// ═══════════════════════════════════════════
// THE SERVICE
// ═══════════════════════════════════════════

/// Talks to the custom NLP backend that understands both English and Urdu
/// voice commands.
///
/// This service is deliberately dumb: it takes recognised speech text in and
/// hands a classified intent back. Deciding *which* device the intent applies
/// to is `VoiceCommandMapper`'s job.
class NlpApiService {
  final http.Client _client;

  /// [client] can be injected in tests; production uses a real HTTP client.
  NlpApiService({http.Client? client}) : _client = client ?? http.Client();

  /// Sends [text] to `POST /predict` and returns the classified intent.
  ///
  /// Never throws. Network problems, timeouts, server errors and malformed
  /// bodies all come back as a [NlpResult] with `success == false` and a
  /// user-friendly [NlpResult.message].
  Future<NlpResult> predict(String text) async {
    final trimmed = text.trim();

    if (trimmed.isEmpty) {
      return NlpResult.failure(
        NlpErrorType.badResponse,
        'I did not catch anything. Please tap the mic and speak again.',
      );
    }

    try {
      final response = await _client
          .post(
            NlpApiConfig.predictUri,
            headers: const {
              'Content-Type': 'application/json; charset=utf-8',
              'Accept': 'application/json',
            },
            // jsonEncode escapes Urdu characters to \uXXXX, which is valid JSON
            // and survives any server-side encoding.
            body: jsonEncode({'text': trimmed}),
          )
          .timeout(NlpApiConfig.requestTimeout);

      if (response.statusCode != 200) {
        debugPrint('NLP API ${response.statusCode}: ${response.body}');
        return NlpResult.failure(
          NlpErrorType.serverError,
          'The language server reported an error (code ${response.statusCode}).\n'
          'Please try again in a moment.',
        );
      }

      // Decode the BYTES as UTF-8. Using `response.body` would fall back to
      // latin1 when the server omits a charset, which mangles Urdu text.
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));

      if (decoded is! Map<String, dynamic>) {
        debugPrint('NLP API returned unexpected JSON: $decoded');
        return NlpResult.failure(
          NlpErrorType.badResponse,
          'The language server sent an unexpected reply. Please try again.',
        );
      }

      return NlpResult.success(
        IntentResult.fromJson(decoded, fallbackText: trimmed),
      );
    } on TimeoutException {
      return NlpResult.failure(
        NlpErrorType.timeout,
        'The language server took too long to respond.\n'
        'Check that it is running, then try again.',
      );
    } on SocketException catch (e) {
      debugPrint('NLP API socket error: $e');
      return NlpResult.failure(
        NlpErrorType.noConnection,
        'Could not reach the language server at ${NlpApiConfig.baseUrl}.\n'
        'Check your WiFi and the server address, then try again.',
      );
    } on http.ClientException catch (e) {
      debugPrint('NLP API client error: $e');
      return NlpResult.failure(
        NlpErrorType.noConnection,
        'The connection to the language server was interrupted.\n'
        'Please try again.',
      );
    } on FormatException catch (e) {
      debugPrint('NLP API parse error: $e');
      return NlpResult.failure(
        NlpErrorType.badResponse,
        'The language server sent a reply the app could not read.',
      );
    } catch (e) {
      debugPrint('NLP API unexpected error: $e');
      return NlpResult.failure(
        NlpErrorType.unknown,
        'Something went wrong while understanding your command.\n'
        'Please try again.',
      );
    }
  }

  /// Releases the underlying HTTP connection pool.
  void dispose() => _client.close();
}
