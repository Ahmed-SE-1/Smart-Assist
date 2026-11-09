import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_home/services/main_controller_worker_client.dart';

void main() {
  group('MainControllerWorkerClient', () {
    test(
      'attaches the Firebase ID token and posts the Worker JSON contract',
      () async {
        http.Request? captured;
        final client = MainControllerWorkerClient(
          baseUrl: 'https://smartassist-api.example.workers.dev/',
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'token': List.filled(43, 'a').join(),
                'expiresAt': DateTime.utc(2030).toIso8601String(),
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
          idTokenProvider:
              ({required forceRefresh}) async => 'firebase-id-token',
        );
        addTearDown(client.close);

        final response = await client.post('/v1/controller/pairing-sessions', {
          'houseId': 'house-1',
        });

        expect(captured?.url.path, '/v1/controller/pairing-sessions');
        expect(captured?.headers['authorization'], 'Bearer firebase-id-token');
        expect(captured?.headers['content-type'], 'application/json');
        expect(jsonDecode(captured!.body), {'houseId': 'house-1'});
        expect(response['token'], List.filled(43, 'a').join());
      },
    );

    test(
      'refreshes Firebase ID token once after 401 and retries the request',
      () async {
        var requestCount = 0;
        final forceRefreshValues = <bool>[];
        final client = MainControllerWorkerClient(
          baseUrl: 'https://worker.example',
          client: MockClient((request) async {
            requestCount++;
            if (requestCount == 1) {
              expect(request.headers['authorization'], 'Bearer stale-token');
              return http.Response(
                jsonEncode({
                  'error': {'code': 'unauthenticated', 'message': 'Expired'},
                }),
                401,
                headers: {'content-type': 'application/json'},
              );
            }
            expect(request.headers['authorization'], 'Bearer fresh-token');
            return http.Response(jsonEncode({'status': 'pending'}), 200);
          }),
          idTokenProvider: ({required forceRefresh}) async {
            forceRefreshValues.add(forceRefresh);
            return forceRefresh ? 'fresh-token' : 'stale-token';
          },
        );
        addTearDown(client.close);

        expect(
          await client.get('/v1/controller/unpair-operations/${'o' * 32}'),
          {'status': 'pending'},
        );
        expect(forceRefreshValues, [false, true]);
        expect(requestCount, 2);
      },
    );

    test('maps Worker errors to safe typed exceptions', () async {
      final client = MainControllerWorkerClient(
        baseUrl: 'https://worker.example',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'permission-denied',
                'message': 'Approved House owner access is required.',
              },
            }),
            403,
            headers: {'content-type': 'application/json'},
          ),
        ),
        idTokenProvider: ({required forceRefresh}) async => 'id-token',
      );
      addTearDown(client.close);

      await expectLater(
        client.post('/v1/controller/pairing-sessions', {'houseId': 'house-1'}),
        throwsA(
          isA<WorkerApiException>()
              .having((error) => error.code, 'code', 'permission-denied')
              .having(
                (error) => error.message,
                'message',
                'Approved House owner access is required.',
              ),
        ),
      );
    });

    test(
      'does not issue HTTP request without a signed-in Firebase user',
      () async {
        var requestCount = 0;
        final client = MainControllerWorkerClient(
          baseUrl: 'https://worker.example',
          client: MockClient((_) async {
            requestCount++;
            return http.Response('{}', 200);
          }),
          idTokenProvider: ({required forceRefresh}) async => null,
        );
        addTearDown(client.close);

        await expectLater(
          client.post('/v1/controller/pairing-sessions', {
            'houseId': 'house-1',
          }),
          throwsA(
            isA<WorkerApiException>().having(
              (e) => e.code,
              'code',
              'unauthenticated',
            ),
          ),
        );
        expect(requestCount, 0);
      },
    );

    test('rejects unset or non-HTTPS production base URLs', () async {
      final client = MainControllerWorkerClient(
        baseUrl: 'http://api.example.test',
        client: MockClient((_) async => http.Response('{}', 200)),
        idTokenProvider: ({required forceRefresh}) async => 'id-token',
      );
      addTearDown(client.close);

      await expectLater(
        client.post('/v1/controller/pairing-sessions', {'houseId': 'house-1'}),
        throwsA(
          isA<WorkerApiException>().having(
            (e) => e.code,
            'code',
            'worker-not-configured',
          ),
        ),
      );
    });
  });
}
