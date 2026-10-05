import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/intent_result.dart';

// ═══════════════════════════════════════════
// API CONFIGURATION
// ═══════════════════════════════════════════

class NlpApiConfig {
  NlpApiConfig._();

  /// Hugging Face Space (Gradio) ka direct address.
  static const String baseUrl = 'https://aqeelabdullah654-nlp-model.hf.space';

  /// `api_name="predict"` jo app.py me set hai.
  static const String apiName = 'predict';

  /// Optional. ZeroGPU ka quota bachane ke liye testing me use karein:
  ///   flutter run --dart-define=HF_TOKEN=hf_xxxxx
  /// Release build me kabhi hardcode na karein.
  static const String hfToken = String.fromEnvironment('HF_TOKEN');

  /// Gradio 5 ke liye '/gradio_api', Gradio 4 ke liye ''. Pehla jo chale wohi yaad rakha jata hai.
  static const List<String> apiPrefixes = ['/gradio_api', ''];

  /// ZeroGPU cold start / queue me waqt lagta hai, is liye 8s se zyada rakha hai.
  static const Duration requestTimeout = Duration(seconds: 30);
}

// ═══════════════════════════════════════════
// RESULT / ERROR TYPES
// ═══════════════════════════════════════════

enum NlpErrorType { noConnection, timeout, serverError, badResponse, unknown }

class NlpResult {
  final bool success;
  final IntentResult? intent;
  final NlpErrorType? errorType;
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

/// Andar ki error, jo predict() NlpResult me badal deta hai.
class _NlpException implements Exception {
  final NlpErrorType type;
  final String message;
  _NlpException(this.type, this.message);
}

// ═══════════════════════════════════════════
// THE SERVICE
// ═══════════════════════════════════════════

class NlpApiService {
  final http.Client _client;

  /// Jo prefix kaam kar gaya, wo yaad rakhte hain taake agli calls me dobara
  /// guess na karna pade.
  String? _workingPrefix;

  NlpApiService({http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
    if (NlpApiConfig.hfToken.isNotEmpty)
      'Authorization': 'Bearer ${NlpApiConfig.hfToken}',
  };

  Future<NlpResult> predict(String text) async {
    final trimmed = text.trim();

    if (trimmed.isEmpty) {
      return NlpResult.failure(
        NlpErrorType.badResponse,
        'I did not catch anything. Please tap the mic and speak again.',
      );
    }

    try {
      final json =
      await _callGradio(trimmed).timeout(NlpApiConfig.requestTimeout);
      return NlpResult.success(
        IntentResult.fromJson(json, fallbackText: trimmed),
      );
    } on _NlpException catch (e) {
      return NlpResult.failure(e.type, e.message);
    } on TimeoutException {
      return NlpResult.failure(
        NlpErrorType.timeout,
        'The language server took too long to respond.\n'
            'The Space may be waking up. Please try again.',
      );
    } on SocketException catch (e) {
      debugPrint('NLP API socket error: $e');
      return NlpResult.failure(
        NlpErrorType.noConnection,
        'Could not reach the language server.\n'
            'Check your internet connection, then try again.',
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

  // ── Gradio 2-step call ───────────────────

  Future<Map<String, dynamic>> _callGradio(String text) async {
    final prefixes = _workingPrefix != null
        ? [_workingPrefix!]
        : NlpApiConfig.apiPrefixes;

    // STEP 1: POST -> event_id
    http.Response? post;
    String? usedPrefix;
    for (final prefix in prefixes) {
      final uri = Uri.parse(
        '${NlpApiConfig.baseUrl}$prefix/call/${NlpApiConfig.apiName}',
      );
      final r = await _client.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'data': [text],
        }),
      );
      // 404 ka matlab is Gradio version me ye path nahi hai, agla prefix try karo.
      if (r.statusCode == 404 && prefix != prefixes.last) continue;
      post = r;
      usedPrefix = prefix;
      break;
    }

    if (post == null || post.statusCode != 200) {
      _throwForStatus(post?.statusCode ?? 0, post?.body ?? '');
    }
    _workingPrefix = usedPrefix;

    final eventId = (jsonDecode(utf8.decode(post!.bodyBytes))
    as Map<String, dynamic>)['event_id'] as String?;
    if (eventId == null) {
      throw _NlpException(
        NlpErrorType.badResponse,
        'The language server sent an unexpected reply. Please try again.',
      );
    }

    // STEP 2: GET -> SSE stream (jab tak result na aaye connection khula rehta hai)
    final get = await _client.get(
      Uri.parse(
        '${NlpApiConfig.baseUrl}$usedPrefix/call/${NlpApiConfig.apiName}/$eventId',
      ),
      headers: _headers,
    );
    if (get.statusCode != 200) {
      _throwForStatus(get.statusCode, get.body);
    }

    return _parseSse(utf8.decode(get.bodyBytes));
  }

  /// SSE ka format:
  ///   event: complete
  ///   data: [{"intent": "...", "confidence": 0.9, ...}]
  Map<String, dynamic> _parseSse(String body) {
    String? event;
    for (final line in const LineSplitter().convert(body)) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (event == 'error') {
          debugPrint('NLP Space error event: $data');
          final quota = data.toLowerCase().contains('quota');
          throw _NlpException(
            NlpErrorType.serverError,
            quota
                ? 'The GPU quota for the language server is used up.\n'
                'Please try again in a little while.'
                : 'The language server reported an error.\n'
                'Please try again in a moment.',
          );
        }
        if (event == 'complete') {
          var decoded = jsonDecode(data);
          if (decoded is List && decoded.isNotEmpty) decoded = decoded[0];
          // Agar output string ban kar aaye to ek baar aur decode karo.
          if (decoded is String) decoded = jsonDecode(decoded);
          if (decoded is Map<String, dynamic>) return decoded;
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        }
      }
    }
    debugPrint('NLP API: no complete event in: $body');
    throw _NlpException(
      NlpErrorType.badResponse,
      'The language server sent a reply the app could not read.',
    );
  }

  Never _throwForStatus(int code, String body) {
    debugPrint('NLP API $code: $body');
    if (code == 429) {
      throw _NlpException(
        NlpErrorType.serverError,
        'The language server is busy or its GPU quota is used up.\n'
            'Please try again in a little while.',
      );
    }
    throw _NlpException(
      NlpErrorType.serverError,
      'The language server reported an error (code $code).\n'
          'Please try again in a moment.',
    );
  }

  void dispose() => _client.close();
}