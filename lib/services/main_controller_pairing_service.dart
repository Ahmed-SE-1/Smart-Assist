import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/user.dart';
import 'registration_service.dart';

/// Stable GATT contract shared with the future Main ESP32 firmware.
abstract final class MainControllerBleProtocol {
  static const serviceUuid = '9b0a1000-6f2a-4d71-9c3e-2a4b5c6d7e80';
  static const pairingRequestCharacteristicUuid =
      '9b0a1001-6f2a-4d71-9c3e-2a4b5c6d7e80';
  static const pairingResultCharacteristicUuid =
      '9b0a1002-6f2a-4d71-9c3e-2a4b5c6d7e80';
  static const protocolVersion = 1;

  static String encodeRequest(String token) =>
      jsonEncode({'v': protocolVersion, 'token': token});
}

final _mainControllerServiceUuid = Uuid.parse(
  MainControllerBleProtocol.serviceUuid,
);
final _pairingRequestCharacteristicUuid = Uuid.parse(
  MainControllerBleProtocol.pairingRequestCharacteristicUuid,
);
final _pairingResultCharacteristicUuid = Uuid.parse(
  MainControllerBleProtocol.pairingResultCharacteristicUuid,
);

class MainControllerBleDevice {
  const MainControllerBleDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;
}

class MainControllerPairingSession {
  const MainControllerPairingSession({
    required this.token,
    required this.expiresAt,
  });

  /// Kept in memory only. Never persist or log this value.
  final String token;
  final DateTime expiresAt;
}

class ControllerRegistryState {
  const ControllerRegistryState({
    required this.houseExists,
    this.controllerId,
    this.status,
    this.pairedAt,
    this.lastSeenAt,
    this.unpairOperationId,
    this.unpairStatus,
  });

  final bool houseExists;
  final String? controllerId;
  final String? status;
  final DateTime? pairedAt;
  final DateTime? lastSeenAt;
  final String? unpairOperationId;
  final String? unpairStatus;

  bool get isPaired => controllerId != null && controllerId!.isNotEmpty;
}

class MainControllerPairingException implements Exception {
  const MainControllerPairingException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class MainControllerUnpairOperation {
  const MainControllerUnpairOperation({
    required this.operationId,
    required this.houseId,
    required this.controllerId,
    required this.status,
    this.expiresAt,
  });

  final String operationId;
  final String houseId;
  final String controllerId;
  final String status;
  final DateTime? expiresAt;

  factory MainControllerUnpairOperation.fromMap(Map<String, dynamic> map) {
    final operationId = map['operationId'];
    final houseId = map['houseId'];
    final controllerId = map['controllerId'];
    final status = map['status'];
    final expiry = map['expiresAt'];
    if (operationId is! String ||
        houseId is! String ||
        controllerId is! String ||
        status is! String) {
      throw const MainControllerPairingException(
        'invalid-unpair-operation',
        'The unpair service returned an invalid operation.',
      );
    }
    return MainControllerUnpairOperation(
      operationId: operationId,
      houseId: houseId,
      controllerId: controllerId,
      status: status,
      expiresAt: expiry is String ? DateTime.tryParse(expiry) : null,
    );
  }
}

abstract interface class MainControllerBleConnection {
  Future<void> verifyProtocol();
  Stream<List<int>> get pairingResults;
  Future<void> writePairingRequest(String jsonRequest);
  Future<void> close();
}

abstract interface class MainControllerBleAdapter {
  Stream<MainControllerBleDevice> scanForControllers();
  Future<MainControllerBleConnection> connect(
    MainControllerBleDevice device, {
    required Duration timeout,
  });
}

abstract interface class ControllerRegistryReader {
  Stream<ControllerRegistryState> watchHouse(String houseId);
  Future<Map<String, dynamic>?> getHouse(String houseId);
  Future<Map<String, dynamic>?> getController(String controllerId);
}

class FirestoreControllerRegistryReader implements ControllerRegistryReader {
  FirestoreControllerRegistryReader({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Stream<ControllerRegistryState> watchHouse(String houseId) {
    return _firestore.collection('houses').doc(houseId).snapshots().asyncMap((
      houseDoc,
    ) async {
      final house = houseDoc.data();
      if (!houseDoc.exists || house == null) {
        return const ControllerRegistryState(houseExists: false);
      }
      final controllerId = house['mainControllerId'];
      final operationId =
          house['pendingUnpairOperationId'] is String
              ? house['pendingUnpairOperationId'] as String
              : house['lastUnpairOperationId'] is String
              ? house['lastUnpairOperationId'] as String
              : null;
      final operation =
          operationId == null
              ? null
              : (await _firestore
                      .collection('controllerUnpairOperations')
                      .doc(operationId)
                      .get())
                  .data();
      final operationStatus =
          operation?['status'] is String
              ? operation!['status'] as String
              : null;
      if (controllerId is! String || controllerId.isEmpty) {
        return ControllerRegistryState(
          houseExists: true,
          unpairOperationId: operationId,
          unpairStatus: operationStatus,
        );
      }
      final controller = await getController(controllerId);
      return ControllerRegistryState(
        houseExists: true,
        controllerId: controllerId,
        status:
            controller?['status'] is String
                ? controller!['status'] as String
                : 'unknown',
        pairedAt: _date(controller?['pairedAt']),
        lastSeenAt: _date(controller?['lastSeenAt']),
        unpairOperationId: operationId,
        unpairStatus: operationStatus,
      );
    });
  }

  @override
  Future<Map<String, dynamic>?> getHouse(String houseId) async {
    final snapshot = await _firestore.collection('houses').doc(houseId).get();
    return snapshot.data();
  }

  @override
  Future<Map<String, dynamic>?> getController(String controllerId) async {
    final snapshot =
        await _firestore.collection('controllers').doc(controllerId).get();
    return snapshot.data();
  }

  DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }
}

/// Concrete Android/iOS BLE transport. UI and orchestration can use mocks
/// through [MainControllerBleAdapter] without requiring a physical ESP32.
class FlutterReactiveMainControllerBleAdapter
    implements MainControllerBleAdapter {
  FlutterReactiveMainControllerBleAdapter({FlutterReactiveBle? ble})
    : _ble = ble ?? FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  @override
  Stream<MainControllerBleDevice> scanForControllers() async* {
    await _ensureReady();
    yield* _ble
        .scanForDevices(
          withServices: [_mainControllerServiceUuid],
          scanMode: ScanMode.lowLatency,
        )
        .map(
          (device) => MainControllerBleDevice(
            id: device.id,
            name:
                device.name.trim().isEmpty ? 'Main ESP32' : device.name.trim(),
            rssi: device.rssi,
          ),
        );
  }

  @override
  Future<MainControllerBleConnection> connect(
    MainControllerBleDevice device, {
    required Duration timeout,
  }) async {
    await _ensureReady();
    final completer = Completer<void>();
    var wasConnected = false;
    late final StreamSubscription<ConnectionStateUpdate> subscription;
    subscription = _ble
        .connectToAdvertisingDevice(
          id: device.id,
          withServices: [_mainControllerServiceUuid],
          prescanDuration: const Duration(seconds: 3),
          connectionTimeout: timeout,
          servicesWithCharacteristicsToDiscover: {
            _mainControllerServiceUuid: [
              _pairingRequestCharacteristicUuid,
              _pairingResultCharacteristicUuid,
            ],
          },
        )
        .listen(
          (update) {
            if (update.connectionState == DeviceConnectionState.connected) {
              wasConnected = true;
              if (!completer.isCompleted) completer.complete();
            } else if (wasConnected &&
                update.connectionState == DeviceConnectionState.disconnected &&
                !completer.isCompleted) {
              completer.completeError(
                const MainControllerPairingException(
                  'disconnected',
                  'The controller disconnected during pairing.',
                ),
              );
            }
          },
          onError: (Object error) {
            if (!completer.isCompleted) {
              completer.completeError(
                MainControllerPairingException(
                  'connection-failed',
                  'Could not connect to this controller.',
                ),
              );
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.completeError(
                const MainControllerPairingException(
                  'connection-failed',
                  'The controller connection ended unexpectedly.',
                ),
              );
            }
          },
        );

    try {
      await completer.future.timeout(timeout);
      return _FlutterReactiveMainControllerBleConnection(
        ble: _ble,
        deviceId: device.id,
        connectionSubscription: subscription,
      );
    } on TimeoutException {
      await subscription.cancel();
      throw const MainControllerPairingException(
        'connection-timeout',
        'Connection timed out. Move closer and try again.',
      );
    } catch (_) {
      await subscription.cancel();
      rethrow;
    }
  }

  Future<void> _ensureReady() async {
    if (!kIsWeb && Platform.isAndroid) {
      final permissions =
          await <Permission>[
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
          ].request();
      if (permissions.values.any((status) => !status.isGranted)) {
        throw const MainControllerPairingException(
          'permission-denied',
          'Bluetooth permissions are required to find the controller.',
        );
      }
      // Android 11 and earlier require location permission for BLE scanning.
      // The manifest caps this permission at API 30, so newer Android versions
      // rely only on the Bluetooth scan/connect permissions above.
      await Permission.locationWhenInUse.request();
    }
    if (_ble.status != BleStatus.ready) {
      throw const MainControllerPairingException(
        'bluetooth-unavailable',
        'Turn on Bluetooth and allow nearby-device access.',
      );
    }
  }
}

class _FlutterReactiveMainControllerBleConnection
    implements MainControllerBleConnection {
  _FlutterReactiveMainControllerBleConnection({
    required FlutterReactiveBle ble,
    required this.deviceId,
    required StreamSubscription<ConnectionStateUpdate> connectionSubscription,
  }) : _ble = ble,
       _connectionSubscription = connectionSubscription;

  final FlutterReactiveBle _ble;
  final String deviceId;
  final StreamSubscription<ConnectionStateUpdate> _connectionSubscription;
  late QualifiedCharacteristic _requestCharacteristic;
  late QualifiedCharacteristic _resultCharacteristic;

  @override
  Future<void> verifyProtocol() async {
    await _ble.discoverAllServices(deviceId);
    final services = await _ble.getDiscoveredServices(deviceId);
    Service? expectedService;
    for (final service in services) {
      if (service.id.toString().toLowerCase() ==
          MainControllerBleProtocol.serviceUuid) {
        expectedService = service;
        break;
      }
    }
    if (expectedService == null) {
      throw const MainControllerPairingException(
        'invalid-service',
        'This device does not expose the SmartAssist controller service.',
      );
    }

    Characteristic? request;
    Characteristic? result;
    for (final characteristic in expectedService.characteristics) {
      final uuid = characteristic.id.toString().toLowerCase();
      if (uuid == MainControllerBleProtocol.pairingRequestCharacteristicUuid) {
        request = characteristic;
      } else if (uuid ==
          MainControllerBleProtocol.pairingResultCharacteristicUuid) {
        result = characteristic;
      }
    }
    if (request == null ||
        !request.isWritableWithResponse ||
        result == null ||
        (!result.isNotifiable && !result.isIndicatable)) {
      throw const MainControllerPairingException(
        'invalid-characteristics',
        'The controller pairing characteristics are incomplete.',
      );
    }

    _requestCharacteristic = QualifiedCharacteristic(
      serviceId: _mainControllerServiceUuid,
      characteristicId: _pairingRequestCharacteristicUuid,
      deviceId: deviceId,
    );
    _resultCharacteristic = QualifiedCharacteristic(
      serviceId: _mainControllerServiceUuid,
      characteristicId: _pairingResultCharacteristicUuid,
      deviceId: deviceId,
    );

    // The JSON request is larger than the default ATT payload. Firmware should
    // support GATT long writes; ask for a larger MTU where the platform allows.
    await _ble.requestMtu(deviceId: deviceId, mtu: 185);
  }

  @override
  Stream<List<int>> get pairingResults =>
      _ble.subscribeToCharacteristic(_resultCharacteristic);

  @override
  Future<void> writePairingRequest(String jsonRequest) =>
      _ble.writeCharacteristicWithResponse(
        _requestCharacteristic,
        value: utf8.encode(jsonRequest),
      );

  @override
  Future<void> close() => _connectionSubscription.cancel();
}

class ControllerPairingService {
  ControllerPairingService({
    required CallableInvoker callable,
    required MainControllerBleAdapter ble,
    required ControllerRegistryReader registry,
  }) : _callable = callable,
       _ble = ble,
       _registry = registry;

  final CallableInvoker _callable;
  final MainControllerBleAdapter _ble;
  final ControllerRegistryReader _registry;
  Completer<void>? _pairingCancellation;
  MainControllerBleConnection? _activeConnection;

  Stream<ControllerRegistryState> watchHouse(String houseId) =>
      _registry.watchHouse(houseId);

  Stream<MainControllerBleDevice> scanForControllers() =>
      _ble.scanForControllers();

  Future<void> cancelPairing() async {
    final cancellation = _pairingCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    await _activeConnection?.close();
  }

  Future<MainControllerPairingSession> createPairingSession(User user) async {
    final houseId = _approvedOwnerHouseId(user);
    final response = await _callable.call('createControllerPairingSession', {
      'houseId': houseId,
    });
    final token = response['token'];
    final expiry = response['expiresAt'];
    if (token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        expiry is! String) {
      throw const MainControllerPairingException(
        'invalid-session',
        'The pairing service returned an invalid session.',
      );
    }
    final expiresAt = DateTime.tryParse(expiry);
    if (expiresAt == null || !expiresAt.isAfter(DateTime.now())) {
      throw const MainControllerPairingException(
        'expired-token',
        'The pairing session expired. Start pairing again.',
      );
    }
    return MainControllerPairingSession(token: token, expiresAt: expiresAt);
  }

  Future<({String controllerId, String houseId})> pairWithController({
    required User user,
    required MainControllerPairingSession session,
    required MainControllerBleDevice device,
    void Function(String progress)? onProgress,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration resultTimeout = const Duration(seconds: 45),
  }) async {
    final houseId = _approvedOwnerHouseId(user);
    if (!session.expiresAt.isAfter(DateTime.now())) {
      throw const MainControllerPairingException(
        'expired-token',
        'The pairing token expired. Start pairing again.',
      );
    }

    MainControllerBleConnection? connection;
    final cancellation = Completer<void>();
    _pairingCancellation = cancellation;
    try {
      onProgress?.call('Connecting to controller…');
      final connectFuture = _ble.connect(device, timeout: connectionTimeout);
      connection = await Future.any<MainControllerBleConnection>([
        connectFuture.then((connected) async {
          if (cancellation.isCompleted) {
            await connected.close();
            throw const MainControllerPairingException(
              'cancelled',
              'Controller pairing was cancelled.',
            );
          }
          return connected;
        }),
        _cancelled<MainControllerBleConnection>(cancellation),
      ]);
      _activeConnection = connection;
      onProgress?.call('Checking controller service…');
      await Future.any<void>([
        connection.verifyProtocol(),
        _cancelled<void>(cancellation),
      ]);
      if (!session.expiresAt.isAfter(DateTime.now())) {
        throw const MainControllerPairingException(
          'expired-token',
          'The pairing token expired. Start pairing again.',
        );
      }

      final remaining = session.expiresAt.difference(DateTime.now());
      final waitForResult =
          remaining < resultTimeout ? remaining : resultTimeout;
      onProgress?.call('Waiting for Firebase pairing confirmation…');
      final responseFuture = connection.pairingResults.first.timeout(
        waitForResult,
      );
      await Future.any<void>([
        connection.writePairingRequest(
          MainControllerBleProtocol.encodeRequest(session.token),
        ),
        _cancelled<void>(cancellation),
      ]);
      final responseBytes = await Future.any<List<int>>([
        responseFuture,
        _cancelled<List<int>>(cancellation),
      ]);
      final confirmation = _parseClaimConfirmation(responseBytes, houseId);

      // A notification alone is not treated as success: confirm both trusted
      // registry sides now reflect the claimed controller.
      final house = await _registry.getHouse(houseId);
      final controller = await _registry.getController(
        confirmation.controllerId,
      );
      if (house?['mainControllerId'] != confirmation.controllerId ||
          controller?['activeHouseId'] != houseId ||
          controller?['authCredentialStatus'] != 'active' ||
          controller?['firebaseAuthUid'] !=
              'smartassist-controller-${confirmation.controllerId}') {
        throw const MainControllerPairingException(
          'registry-not-confirmed',
          'Firebase has not confirmed the controller identity and assignment yet.',
        );
      }
      return confirmation;
    } on TimeoutException {
      throw const MainControllerPairingException(
        'result-timeout',
        'The controller did not return a pairing result in time.',
      );
    } finally {
      await connection?.close();
      _activeConnection = null;
      if (identical(_pairingCancellation, cancellation)) {
        _pairingCancellation = null;
      }
    }
  }

  Future<MainControllerUnpairOperation> requestUnpair(
    User user,
    String controllerId,
  ) async {
    final houseId = _approvedOwnerHouseId(user);
    final response = await _callable.call('requestMainControllerUnpair', {
      'houseId': houseId,
      'controllerId': controllerId,
    });
    final operation = MainControllerUnpairOperation.fromMap(response);
    if (operation.houseId != houseId ||
        operation.controllerId != controllerId) {
      throw const MainControllerPairingException(
        'unpair-operation-mismatch',
        'Firebase returned an operation for another controller.',
      );
    }
    return operation;
  }

  Future<MainControllerUnpairOperation> getUnpairOperation(
    User user,
    String operationId,
  ) async {
    final houseId = _approvedOwnerHouseId(user);
    final response = await _callable.call('getMainControllerUnpairOperation', {
      'operationId': operationId,
    });
    final operation = MainControllerUnpairOperation.fromMap(response);
    if (operation.houseId != houseId || operation.operationId != operationId) {
      throw const MainControllerPairingException(
        'unpair-operation-mismatch',
        'Firebase returned an operation for another House.',
      );
    }
    return operation;
  }

  Future<MainControllerUnpairOperation> retryUnpair(
    User user,
    String operationId,
  ) async {
    _approvedOwnerHouseId(user);
    final response = await _callable.call('retryMainControllerUnpair', {
      'operationId': operationId,
    });
    return MainControllerUnpairOperation.fromMap(response);
  }

  String _approvedOwnerHouseId(User user) {
    final houseId = user.houseId?.trim();
    if (user.role != UserRole.owner ||
        !user.isApproved ||
        houseId == null ||
        houseId.isEmpty) {
      throw const MainControllerPairingException(
        'permission-denied',
        'Only an approved House owner can manage the Main Controller.',
      );
    }
    return houseId;
  }

  Future<T> _cancelled<T>(Completer<void> cancellation) =>
      cancellation.future.then<T>((_) {
        throw const MainControllerPairingException(
          'cancelled',
          'Controller pairing was cancelled.',
        );
      });

  ({String controllerId, String houseId}) _parseClaimConfirmation(
    List<int> bytes,
    String expectedHouseId,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) {
        throw const FormatException('Unsupported response.');
      }
      if (decoded['ok'] == false) {
        final error = decoded['error'];
        final code =
            error is Map && error['code'] is String
                ? error['code'] as String
                : 'claim-failed';
        final message =
            code == 'permission-denied'
                ? 'The pairing token expired or was rejected. Start pairing again.'
                : 'The controller could not be paired ($code).';
        throw MainControllerPairingException(code, message);
      }
      final result = decoded['result'];
      if (decoded['ok'] != true ||
          result is! Map<String, dynamic> ||
          result['status'] != 'paired' ||
          result['houseId'] != expectedHouseId ||
          result['controllerId'] is! String ||
          !RegExp(
            r'^CTRL_[A-Za-z0-9_-]{8,56}$',
          ).hasMatch(result['controllerId'] as String)) {
        throw const FormatException('Claim was not confirmed.');
      }
      return (
        controllerId: result['controllerId'] as String,
        houseId: result['houseId'] as String,
      );
    } on MainControllerPairingException {
      rethrow;
    } catch (_) {
      throw const MainControllerPairingException(
        'invalid-result',
        'The controller returned an invalid pairing result.',
      );
    }
  }
}
