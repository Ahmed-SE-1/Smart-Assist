import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smart_home/models/user.dart';
import 'package:smart_home/providers/service_providers.dart';
import 'package:smart_home/providers/user_provider.dart';
import 'package:smart_home/screens/settings/main_controller_pairing_screen.dart';
import 'package:smart_home/services/main_controller_pairing_service.dart';
import 'package:smart_home/services/registration_service.dart';

class _FakeCallable implements CallableInvoker {
  final calls = <({String name, Map<String, dynamic> payload})>[];
  Map<String, dynamic> sessionResponse = {
    'token': List.filled(43, 'a').join(),
    'expiresAt':
        DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
  };
  Map<String, dynamic> unpairResponse = const {};
  Map<String, dynamic> unpairStatusResponse = const {};

  @override
  Future<Map<String, dynamic>> call(
    String functionName,
    Map<String, dynamic> payload,
  ) async {
    calls.add((name: functionName, payload: payload));
    if (functionName == 'createControllerPairingSession')
      return sessionResponse;
    if (functionName == 'requestMainControllerUnpair') return unpairResponse;
    if (functionName == 'getMainControllerUnpairOperation') {
      return unpairStatusResponse;
    }
    if (functionName == 'retryMainControllerUnpair') return unpairResponse;
    fail('Unexpected callable $functionName');
  }
}

class _FakeRegistry implements ControllerRegistryReader {
  final houseData = <String, Map<String, dynamic>?>{};
  final controllerData = <String, Map<String, dynamic>?>{};
  final states = <String, ControllerRegistryState>{};

  @override
  Stream<ControllerRegistryState> watchHouse(String houseId) => Stream.value(
    states[houseId] ?? const ControllerRegistryState(houseExists: true),
  );

  @override
  Future<Map<String, dynamic>?> getHouse(String houseId) async =>
      houseData[houseId];

  @override
  Future<Map<String, dynamic>?> getController(String controllerId) async =>
      controllerData[controllerId];
}

class _FakeBleAdapter implements MainControllerBleAdapter {
  final scanResults = StreamController<MainControllerBleDevice>.broadcast();
  MainControllerBleConnection? connection;
  Object? connectionError;
  int connectCalls = 0;

  @override
  Stream<MainControllerBleDevice> scanForControllers() => scanResults.stream;

  @override
  Future<MainControllerBleConnection> connect(
    MainControllerBleDevice device, {
    required Duration timeout,
  }) async {
    connectCalls++;
    if (connectionError case final error?) throw error;
    return connection!;
  }
}

class _FakeBleConnection implements MainControllerBleConnection {
  final notifications = StreamController<List<int>>();
  Object? verifyError;
  String? writtenRequest;
  bool closed = false;
  String response = '';

  @override
  Stream<List<int>> get pairingResults => notifications.stream;

  @override
  Future<void> verifyProtocol() async {
    if (verifyError case final error?) throw error;
  }

  @override
  Future<void> writePairingRequest(String jsonRequest) async {
    writtenRequest = jsonRequest;
    notifications.add(utf8.encode(response));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (notifications.hasListener) await notifications.close();
  }
}

class _Harness {
  _Harness()
    : callable = _FakeCallable(),
      ble = _FakeBleAdapter(),
      registry = _FakeRegistry() {
    service = ControllerPairingService(
      callable: callable,
      ble: ble,
      registry: registry,
    );
  }

  final _FakeCallable callable;
  final _FakeBleAdapter ble;
  final _FakeRegistry registry;
  late final ControllerPairingService service;
}

class _FixedUserNotifier extends UserNotifier {
  _FixedUserNotifier(this.value);
  final User? value;

  @override
  User? build() => value;
}

final _owner = User(
  id: 'owner-1',
  name: 'Owner',
  email: 'owner@example.com',
  role: UserRole.owner,
  houseId: 'owner-1',
  isApproved: true,
);

const _device = MainControllerBleDevice(
  id: 'ble-device',
  name: 'SmartAssist',
  rssi: -45,
);
const _controllerId = 'CTRL_abcdefgh1234';

void _respond(
  _FakeBleConnection connection, {
  required bool ok,
  String code = 'permission-denied',
}) {
  connection.response =
      ok
          ? jsonEncode({
            'v': 1,
            'ok': true,
            'result': {
              'houseId': 'owner-1',
              'controllerId': _controllerId,
              'status': 'paired',
            },
          })
          : jsonEncode({
            'v': 1,
            'ok': false,
            'error': {'code': code},
          });
}

void main() {
  test(
    'members and unapproved owners cannot create pairing sessions',
    () async {
      final harness = _Harness();
      await expectLater(
        harness.service.createPairingSession(
          _owner.copyWith(role: UserRole.member),
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
      await expectLater(
        harness.service.createPairingSession(
          _owner.copyWith(isApproved: false),
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
      expect(harness.callable.calls, isEmpty);
    },
  );

  test(
    'approved owner creates a backend pairing session for their House',
    () async {
      final harness = _Harness();
      final session = await harness.service.createPairingSession(_owner);
      expect(session.token, List.filled(43, 'a').join());
      expect(session.expiresAt.isAfter(DateTime.now()), isTrue);
      expect(
        harness.callable.calls.single.name,
        'createControllerPairingSession',
      );
      expect(harness.callable.calls.single.payload, {'houseId': 'owner-1'});
    },
  );

  test(
    'scan and connect states use the adapter and verify backend registry confirmation',
    () async {
      final harness = _Harness();
      final connection = _FakeBleConnection();
      _respond(connection, ok: true);
      harness.ble.connection = connection;
      harness.registry.houseData['owner-1'] = {
        'mainControllerId': _controllerId,
      };
      harness.registry.controllerData[_controllerId] = {
        'activeHouseId': 'owner-1',
        'firebaseAuthUid': 'smartassist-controller-$_controllerId',
        'authCredentialStatus': 'active',
      };

      final found = <MainControllerBleDevice>[];
      final scan = harness.service.scanForControllers().listen(found.add);
      harness.ble.scanResults.add(_device);
      await Future<void>.delayed(Duration.zero);
      await scan.cancel();
      expect(found.single.id, _device.id);

      final session = await harness.service.createPairingSession(_owner);
      final paired = await harness.service.pairWithController(
        user: _owner,
        session: session,
        device: _device,
      );
      expect(harness.ble.connectCalls, 1);
      expect(paired.houseId, 'owner-1');
      expect(paired.controllerId, _controllerId);
      expect(jsonDecode(connection.writtenRequest!)['token'], session.token);
      expect(connection.closed, isTrue);
      expect(
        harness.callable.calls.where(
          (call) => call.name == 'claimMainController',
        ),
        isEmpty,
      );
    },
  );

  test('pairing does not report success until Firebase identity provisioning is active', () async {
    final harness = _Harness();
    final connection = _FakeBleConnection();
    _respond(connection, ok: true);
    harness.ble.connection = connection;
    harness.registry.houseData['owner-1'] = {'mainControllerId': _controllerId};
    harness.registry.controllerData[_controllerId] = {'activeHouseId': 'owner-1'};
    final session = await harness.service.createPairingSession(_owner);

    await expectLater(
      harness.service.pairWithController(
        user: _owner,
        session: session,
        device: _device,
      ),
      throwsA(isA<MainControllerPairingException>().having(
        (error) => error.code,
        'code',
        'registry-not-confirmed',
      )),
    );
  });

  test('invalid GATT service prevents token write', () async {
    final harness = _Harness();
    final connection =
        _FakeBleConnection()
          ..verifyError = const MainControllerPairingException(
            'invalid-service',
            'Invalid service',
          );
    harness.ble.connection = connection;
    final session = await harness.service.createPairingSession(_owner);

    await expectLater(
      harness.service.pairWithController(
        user: _owner,
        session: session,
        device: _device,
      ),
      throwsA(isA<MainControllerPairingException>()),
    );
    expect(connection.writtenRequest, isNull);
    expect(connection.closed, isTrue);
  });

  test(
    'connection timeout is surfaced without pretending the controller paired',
    () async {
      final harness =
          _Harness()
            ..ble.connectionError = const MainControllerPairingException(
              'connection-timeout',
              'Connection timed out',
            );
      final session = await harness.service.createPairingSession(_owner);

      await expectLater(
        harness.service.pairWithController(
          user: _owner,
          session: session,
          device: _device,
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
    },
  );

  test(
    'expired session is rejected before attempting BLE connection',
    () async {
      final harness = _Harness();
      final session = MainControllerPairingSession(
        token: List.filled(43, 'a').join(),
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      await expectLater(
        harness.service.pairWithController(
          user: _owner,
          session: session,
          device: _device,
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
      expect(harness.ble.connectCalls, 0);
    },
  );

  test(
    'failed backend result is displayed as failure and not verified as success',
    () async {
      final harness = _Harness();
      final connection = _FakeBleConnection();
      _respond(connection, ok: false, code: 'permission-denied');
      harness.ble.connection = connection;
      final session = await harness.service.createPairingSession(_owner);

      await expectLater(
        harness.service.pairWithController(
          user: _owner,
          session: session,
          device: _device,
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
      expect(harness.registry.houseData, isEmpty);
      expect(connection.closed, isTrue);
    },
  );

  test(
    'success message requires matching backend result and both House/controller records',
    () async {
      final harness = _Harness();
      final connection = _FakeBleConnection();
      _respond(connection, ok: true);
      harness.ble.connection = connection;
      harness.registry.houseData['owner-1'] = {
        'mainControllerId': 'different-controller',
      };
      harness.registry.controllerData[_controllerId] = {
        'activeHouseId': 'owner-1',
      };
      final session = await harness.service.createPairingSession(_owner);

      await expectLater(
        harness.service.pairWithController(
          user: _owner,
          session: session,
          device: _device,
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
    },
  );

  test(
    'unpair request uses the owner callable and rejects members before calling it',
    () async {
      final harness =
          _Harness()
            ..callable.unpairResponse = const {
              'houseId': 'owner-1',
              'controllerId': _controllerId,
              'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'status': 'pending',
            };
      await expectLater(
        harness.service.requestUnpair(
          _owner.copyWith(role: UserRole.member),
          _controllerId,
        ),
        throwsA(isA<MainControllerPairingException>()),
      );
      expect(harness.callable.calls, isEmpty);

      final operation = await harness.service.requestUnpair(
        _owner,
        _controllerId,
      );
      expect(operation.status, 'pending');
      expect(harness.callable.calls.single.name, 'requestMainControllerUnpair');
      expect(harness.callable.calls.single.payload, {
        'houseId': 'owner-1',
        'controllerId': _controllerId,
      });
    },
  );

  testWidgets(
    'unpair requires confirmation and member screen has no pairing actions',
    (tester) async {
      final harness =
          _Harness()
            ..callable.unpairResponse = const {
              'houseId': 'owner-1',
              'controllerId': _controllerId,
              'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'status': 'pending',
            };
      harness.callable.unpairStatusResponse = {
        'houseId': 'owner-1',
        'controllerId': _controllerId,
        'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'status': 'completed',
      };
      harness.registry.states['owner-1'] = const ControllerRegistryState(
        houseExists: true,
        controllerId: _controllerId,
        status: 'paired',
      );
      final overrides = [
        controllerPairingServiceProvider.overrideWithValue(harness.service),
        userProvider.overrideWith(() => _FixedUserNotifier(_owner)),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const MaterialApp(home: MainControllerPairingScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Main Controller connected'), findsOneWidget);

      await tester.tap(find.text('Disconnect Controller'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect Main Controller?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        harness.callable.calls.where(
          (call) => call.name == 'requestMainControllerUnpair',
        ),
        isEmpty,
      );

      await tester.tap(find.text('Disconnect Controller'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(
        harness.callable.calls.where(
          (call) => call.name == 'requestMainControllerUnpair',
        ),
        hasLength(1),
      );
      expect(
        find.text('Main Controller successfully disconnected.'),
        findsOneWidget,
      );
      expect(
        harness.callable.calls.any(
          (call) => call.name == 'getMainControllerUnpairOperation',
        ),
        isTrue,
      );

      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('member-scope'),
          overrides: [
            controllerPairingServiceProvider.overrideWithValue(harness.service),
            userProvider.overrideWith(
              () => _FixedUserNotifier(_owner.copyWith(role: UserRole.member)),
            ),
          ],
          child: const MaterialApp(home: MainControllerPairingScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Only an approved House owner'),
        findsOneWidget,
      );
      expect(find.text('Start pairing'), findsNothing);
    },
  );

  testWidgets('pending unpair never displays successful disconnection', (
    tester,
  ) async {
    const operationId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final harness =
        _Harness()
          ..callable.unpairStatusResponse = const {
            'houseId': 'owner-1',
            'controllerId': _controllerId,
            'operationId': operationId,
            'status': 'pending',
          };
    harness.registry.states['owner-1'] = const ControllerRegistryState(
      houseExists: true,
      controllerId: _controllerId,
      status: 'unpair_pending',
      unpairOperationId: operationId,
      unpairStatus: 'pending',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controllerPairingServiceProvider.overrideWithValue(harness.service),
          userProvider.overrideWith(() => _FixedUserNotifier(_owner)),
        ],
        child: const MaterialApp(home: MainControllerPairingScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Unpair pending'), findsOneWidget);
    expect(
      find.text('Main Controller successfully disconnected'),
      findsNothing,
    );
    expect(
      harness.callable.calls.any(
        (call) => call.name == 'getMainControllerUnpairOperation',
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
