import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:uuid/uuid.dart';

import '../core/mqtt_config.dart';
import '../models/device.dart';
import 'iot_simulation_service.dart';

/// Owns the one MQTT client used by the optional Phase-1 broker diagnostic.
/// Devices not explicitly mapped continue through [IoTSimulationService].
class MqttService {
  MqttService({MqttConfig? config, IoTSimulationService? simulation})
      : _config = config ?? const MqttConfig(),
        _simulation = simulation ?? IoTSimulationService();

  final MqttConfig _config;
  final IoTSimulationService _simulation;
  final Uuid _uuid = const Uuid();
  MqttServerClient? _client;
  Future<CommandResult>? _connecting;
  bool _disposed = false;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<CommandResult> connect() {
    if (_disposed) return Future.value(_result(false, 'MQTT service is disposed.'));
    if (isConnected) return Future.value(_result(true));
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<CommandResult> _connect() async {
    if (!_config.enabled) return _result(false, 'Real MQTT test mode is disabled.');
    final error = _config.connectionError;
    if (error != null) return _result(false, error);

    final configuredId = _config.clientId.trim();
    if (configuredId == 'smartassist-backend') {
      return _result(false, 'MQTT client ID must not be smartassist-backend.');
    }
    final clientId = configuredId.isNotEmpty
        ? configuredId
        : 'smartassist-flutter-${_randomSuffix()}';
    final client = MqttServerClient.withPort(_config.host, clientId, _config.port);
    client.setProtocolV311();
    client.secure = true;
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = false;
    client.onConnected = () {
      _log('MQTT connected');
    };
    client.onDisconnected = () {
      _log('MQTT disconnected');
    };
    client.logging(on: kDebugMode);

    try {
      // A private CA is explicitly trusted; certificate verification stays on.
      final certificate = await rootBundle.load(_config.caAsset);
      final context = SecurityContext(withTrustedRoots: false);
      context.setTrustedCertificatesBytes(certificate.buffer.asUint8List());
      client.securityContext = context;
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .authenticateAs(_config.username, _config.password)
          .startClean();

      _log(
        'MQTT config: protocol=3.1.1 tls=${client.secure} '
        'host=${_config.host} port=${_config.port} caAsset=${_config.caAsset}',
      );
      _log('MQTT connecting');
      await client.connect();
      final connectionStatus = client.connectionStatus;
      _log('MQTT connection outcome: state=${connectionStatus?.state}');
      if (connectionStatus?.state != MqttConnectionState.connected) {
        client.disconnect();
        return _result(false, 'MQTT connection was rejected by the broker.');
      }
      _client = client;
      return _result(true);
    } catch (error) {
      client.disconnect();
      _log('MQTT connection failed: $error');
      return _result(false, 'MQTT connection failed: $error');
    }
  }

  /// Publishes exactly the Phase-1 ON/OFF command contract at QoS 1.
  Future<CommandResult> publishDeviceCommand({
    required String houseId,
    required String mqttDeviceId,
    required int channel,
    required String state,
  }) async {
    if (houseId.trim().isEmpty) return _result(false, 'MQTT house ID is required.');
    if (mqttDeviceId.trim().isEmpty) return _result(false, 'MQTT device ID is required.');
    if (channel < 1) return _result(false, 'MQTT channel must be at least 1.');
    if (state != 'ON' && state != 'OFF') {
      return _result(false, 'MQTT state must be ON or OFF.');
    }

    final connected = await connect();
    if (!connected.success) return connected;
    final client = _client;
    if (client == null || !isConnected) return _result(false, 'MQTT is disconnected.');

    final cmdId = _uuid.v4();
    final topic = 'smartassist/${houseId.trim()}/${mqttDeviceId.trim()}/cmd';
    final payload = jsonEncode({
      'cmdId': cmdId,
      'channel': channel,
      'state': state,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    final builder = MqttClientPayloadBuilder()..addString(payload);
    try {
      _log('MQTT PUBLISH topic=$topic cmdId=$cmdId channel=$channel state=$state qos=1 retain=false');
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!, retain: false);
      _log('MQTT publish accepted');
      return _result(true);
    } catch (error) {
      _log('MQTT publish failed: $error');
      return _result(false, 'MQTT publish failed: $error');
    }
  }

  /// Existing simulation fallback for fan/AC and unmapped devices.
  Future<CommandResult> publishCommand({
    required Device device,
    required String action,
    required String method,
  }) => _simulation.sendCommand(
        deviceId: device.id,
        roomId: device.roomId,
        action: action,
        method: method,
      );

  void disconnect() {
    _client?.disconnect();
    _client = null;
  }

  void dispose() {
    _disposed = true;
    disconnect();
  }

  CommandResult _result(bool success, [String? message]) => CommandResult(
        success: success,
        deviceId: '',
        roomId: '',
        action: '',
        method: 'mqtt',
        timestamp: DateTime.now(),
        message: message,
      );

  String _randomSuffix() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 20).toRadixString(36)}';

  void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
