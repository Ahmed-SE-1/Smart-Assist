import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

abstract interface class MainControllerApi {
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);
  Future<Map<String, dynamic>> get(String path);
}

class WorkerApiException implements Exception {
  const WorkerApiException(this.code, this.message, {this.statusCode});
  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

typedef FirebaseIdTokenProvider =
    Future<String?> Function({required bool forceRefresh});

class MainControllerWorkerClient implements MainControllerApi {
  MainControllerWorkerClient({
    String? baseUrl,
    http.Client? client,
    FirebaseIdTokenProvider? idTokenProvider,
  }) : _baseUrl =
           (baseUrl ??
                   const String.fromEnvironment('SMARTASSIST_WORKER_BASE_URL'))
               .trim(),
       _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _firebaseIdToken;

  final String _baseUrl;
  final http.Client _client;
  final FirebaseIdTokenProvider _idTokenProvider;

  static Future<String?> _firebaseIdToken({required bool forceRefresh}) async {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    return user?.getIdToken(forceRefresh);
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _send('POST', path, body);

  @override
  Future<Map<String, dynamic>> get(String path) => _send('GET', path, null);

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final base = Uri.tryParse(_baseUrl);
    if (base == null ||
        base.host.isEmpty ||
        (base.scheme != 'https' &&
            !(kDebugMode &&
                base.scheme == 'http' &&
                (base.host == 'localhost' || base.host == '127.0.0.1')))) {
      throw const WorkerApiException(
        'worker-not-configured',
        'Controller service is not configured for this app build.',
      );
    }
    if (!path.startsWith('/v1/controller/')) {
      throw const WorkerApiException(
        'invalid-route',
        'Controller service route is invalid.',
      );
    }
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      query: null,
      fragment: null,
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _idTokenProvider(forceRefresh: attempt == 1);
      if (token == null || token.isEmpty) {
        throw const WorkerApiException(
          'unauthenticated',
          'Sign in again to manage the Main Controller.',
          statusCode: 401,
        );
      }
      http.Response response;
      try {
        final request = http.Request(method, uri)
          ..headers.addAll({
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          });
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        response = await http.Response.fromStream(
          await _client.send(request),
        ).timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw const WorkerApiException(
          'timeout',
          'The controller service timed out. Try again.',
        );
      } on http.ClientException {
        throw const WorkerApiException(
          'network-error',
          'Could not reach the controller service. Check your connection.',
        );
      }

      if (response.statusCode == 401 && attempt == 0) continue;
      final decoded = _decodeResponse(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error'];
        final errorMap = error is Map ? error : const <String, dynamic>{};
        final code =
            errorMap['code'] is String
                ? errorMap['code'] as String
                : _codeFromStatus(response.statusCode);
        final message =
            errorMap['message'] is String
                ? (errorMap['message'] as String).trim()
                : '';
        throw WorkerApiException(
          code,
          message.isEmpty ? _safeMessage(code) : message,
          statusCode: response.statusCode,
        );
      }
      return decoded;
    }
    throw const WorkerApiException(
      'unauthenticated',
      'Your session has expired. Sign in again and retry.',
      statusCode: 401,
    );
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Avoid exposing or logging an upstream response body.
    }
    throw WorkerApiException(
      'invalid-response',
      response.statusCode >= 200 && response.statusCode < 300
          ? 'The controller service returned an invalid response.'
          : _safeMessage(_codeFromStatus(response.statusCode)),
      statusCode: response.statusCode,
    );
  }

  String _codeFromStatus(int status) => switch (status) {
    401 => 'unauthenticated',
    403 => 'permission-denied',
    404 => 'not-found',
    409 => 'already-exists',
    412 => 'failed-precondition',
    413 || 429 => 'resource-exhausted',
    >= 500 => 'unavailable',
    _ => 'request-failed',
  };

  String _safeMessage(String code) => switch (code) {
    'unauthenticated' => 'Your session has expired. Sign in again and retry.',
    'permission-denied' => 'You are not authorized to manage this controller.',
    'invalid-argument' =>
      'The controller request was invalid. Check the details and retry.',
    'not-found' => 'The requested controller operation was not found.',
    'already-exists' =>
      'This House already has a controller or active operation.',
    'failed-precondition' => 'The controller state changed. Refresh and retry.',
    'resource-exhausted' => 'Too many requests. Wait briefly and retry.',
    'unavailable' => 'The controller service is temporarily unavailable.',
    _ => 'The controller request could not be completed.',
  };

  void close() => _client.close();
}
