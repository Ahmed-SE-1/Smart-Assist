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
import '../models/pir_motion_event.dart';
import '../models/room.dart';
import 'iot_simulation_service.dart';

/// Owns the one MQTT client used for mapped fan and light ON/OFF commands.
///
/// A successful publish means the broker accepted the message. It does not
/// mean the ESP32 acknowledged the relay.
class MqttService {
  MqttService({MqttConfig? config, IoTSimulationService? simulation})
    : _config = config ?? const MqttConfig(),
      _simulation = simulation ?? IoTSimulationService();

  final MqttConfig _config;
  final IoTSimulationService _simulation;
  final Uuid _uuid = const Uuid();
  final String _sessionSuffix = _newSessionSuffix();
  final StreamController<PirMotionEvent> _motionController =
      StreamController<PirMotionEvent>.broadcast();
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  Future<CommandResult>? _connecting;
  String? _eventHouseId;
  String? _subscribedTopic;
  int _subscribeTicket = 0;
  bool _disposed = false;

  /// Parsed PIR events from `smartassist/{houseId}/+/events`.
  Stream<PirMotionEvent> get motionEvents => _motionController.stream;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  /// `smartassist/{houseId}/{mqttNodeId}/cmd`
  static String commandTopic(String houseId, String mqttNodeId) =>
      'smartassist/${houseId.trim()}/${mqttNodeId.trim()}/cmd';

  /// House-wide PIR events. One wildcard, not a second client.
  static String eventSubscriptionTopic(String houseId) =>
      'smartassist/${houseId.trim()}/+/events';

  /// Payload fields the tested firmware parser is known to accept.
  static Map<String, dynamic> commandPayload({
    required String cmdId,
    required int channel,
    required String state,
  }) => {'cmdId': cmdId, 'channel': channel, 'state': state};

  /// Keeps a configured id from colliding across installs by appending a
  /// per-process suffix. An empty id gets a generated SmartAssist id.
  static String resolveClientId({
    required String configured,
    required String sessionSuffix,
  }) {
    final trimmed = configured.trim();
    if (trimmed.isEmpty) return 'smartassist-flutter-$sessionSuffix';
    return '$trimmed-$sessionSuffix';
  }

  Future<CommandResult> connect() {
    if (_disposed) {
      return Future.value(_result(false, 'MQTT service is disposed.'));
    }
    if (isConnected) return Future.value(_result(true));
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<CommandResult> _connect() async {
    if (_disposed) return _result(false, 'MQTT service is disposed.');
    if (!_config.enabled) return _result(false, 'Real MQTT is disabled.');
    final error = _config.connectionError;
    if (error != null) return _result(false, error);
    if (isConnected) return _result(true);

    final configuredId = _config.clientId.trim();
    if (configuredId == 'smartassist-backend') {
      return _result(false, 'MQTT client ID must not be smartassist-backend.');
    }

    final existing = _client;
    if (existing != null) {
      if (await _awaitExistingClient(existing)) return _result(true);
      final state = existing.connectionStatus?.state;
      if (existing.autoReconnect && state != MqttConnectionState.faulted) {
        return _result(false, 'MQTT is still reconnecting.');
      }
      _dropClient(existing);
    }

    final clientId = resolveClientId(
      configured: configuredId,
      sessionSuffix: _sessionSuffix,
    );
    final client = MqttServerClient.withPort(
      _config.host,
      clientId,
      _config.port,
    );
    client.setProtocolV311();
    client.secure = true;
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
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
      client.connectionMessage =
          MqttConnectMessage()
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
        _dropClient(client);
        return _result(false, 'MQTT connection was rejected by the broker.');
      }
      _client = client;
      _listen(client);
      final houseId = _eventHouseId;
      if (houseId != null) _subscribeEvents(client, houseId);
      return _result(true);
    } catch (error) {
      _dropClient(client);
      _log('MQTT connection failed: $error');
      return _result(false, 'MQTT connection failed: $error');
    }
  }

  /// Publishes a fan or light ON/OFF command at QoS 1.
  ///
  /// Success means the local client queued the publish. The firmware protocol
  /// has no acknowledgement topic, so this does not confirm the relay.
  Future<CommandResult> publishDeviceCommand({
    required String houseId,
    required String mqttDeviceId,
    required int channel,
    required String state,
  }) async {
    if (houseId.trim().isEmpty) {
      return _result(false, 'MQTT house ID is required.');
    }
    final nodeId = mqttDeviceId.trim();
    if (!Room.isSupportedMqttNodeId(nodeId)) {
      return _result(false, 'MQTT node ID must be ROOM1_NODE or ROOM2_NODE.');
    }
    if (channel != 1 && channel != 2) {
      return _result(false, 'MQTT channel must be 1 (fan) or 2 (light).');
    }
    if (state != 'ON' && state != 'OFF') {
      return _result(false, 'MQTT state must be ON or OFF.');
    }

    final connected = await connect();
    if (!connected.success) return connected;
    final client = _client;
    if (client == null || !isConnected) {
      return _result(false, 'MQTT is disconnected.');
    }

    final cmdId = _uuid.v4();
    final topic = commandTopic(houseId, nodeId);
    final payload = jsonEncode(
      commandPayload(cmdId: cmdId, channel: channel, state: state),
    );
    final builder = MqttClientPayloadBuilder()..addString(payload);
    try {
      _log(
        'MQTT PUBLISH topic=$topic cmdId=$cmdId channel=$channel state=$state qos=1 retain=false',
      );
      client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        builder.payload!,
        retain: false,
      );
      _log('MQTT publish queued');
      return _result(
        true,
        'Command sent to the broker. The ESP32 has not confirmed the relay.',
      );
    } catch (error) {
      _log('MQTT publish failed: $error');
      return _result(false, 'MQTT publish failed: $error');
    }
  }

  /// Subscribes the existing client to PIR events for [houseId].
  ///
  /// This does not invent events. Messages appear only if the Main ESP32
  /// publishes them.
  Future<void> subscribeToHouseEvents(String houseId) async {
    final trimmed = houseId.trim();
    if (_disposed || !_config.enabled || trimmed.isEmpty) return;
    final ticket = ++_subscribeTicket;
    _eventHouseId = trimmed;
    final connected = await connect();
    if (_disposed || ticket != _subscribeTicket || !connected.success) return;
    final client = _client;
    if (client == null || !isConnected) return;
    _listen(client);
    _subscribeEvents(client, trimmed);
  }

  void clearHouseEventSubscription() {
    _subscribeTicket++;
    final client = _client;
    final topic = _subscribedTopic;
    _eventHouseId = null;
    _subscribedTopic = null;
    if (client == null || topic == null) return;
    try {
      client.unsubscribe(topic);
    } catch (error) {
      _log('MQTT unsubscribe failed: $error');
    }
  }

  /// Simulation path for AC, sensors, fan speed, and MQTT-disabled controls.
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
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      client.autoReconnect = false;
      client.disconnect();
    } catch (error) {
      _log('MQTT disconnect failed: $error');
    }
  }

  void dispose() {
    _disposed = true;
    _updatesSub?.cancel();
    _updatesSub = null;
    disconnect();
    if (!_motionController.isClosed) _motionController.close();
  }

  void _listen(MqttServerClient client) {
    if (_updatesSub != null) return;
    _updatesSub = client.updates?.listen(
      _onMqttUpdates,
      onError: (Object error) => _log('MQTT update error: $error'),
    );
  }

  void _subscribeEvents(MqttServerClient client, String houseId) {
    final topic = eventSubscriptionTopic(houseId);
    if (_subscribedTopic == topic) return;
    if (_subscribedTopic != null) {
      try {
        client.unsubscribe(_subscribedTopic!);
      } catch (error) {
        _log('MQTT unsubscribe failed: $error');
      }
    }
    client.subscribe(topic, MqttQos.atLeastOnce);
    _subscribedTopic = topic;
    _log('MQTT SUBSCRIBE topic=$topic qos=1');
  }

  void _onMqttUpdates(List<MqttReceivedMessage<MqttMessage>> messages) {
    final houseId = _eventHouseId;
    if (houseId == null || _motionController.isClosed) return;
    for (final message in messages) {
      final payload = message.payload;
      if (payload is! MqttPublishMessage) continue;
      final text = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );
      final event = PirMotionEvent.tryParse(
        topic: message.topic,
        payload: text,
        expectedHouseId: houseId,
      );
      if (event == null) {
        _log('MQTT event ignored topic=${message.topic}');
        continue;
      }
      _motionController.add(event);
    }
  }

  bool _busy(MqttServerClient client) {
    final state = client.connectionStatus?.state;
    return state == MqttConnectionState.connecting ||
        state == MqttConnectionState.disconnecting;
  }

  Future<bool> _awaitExistingClient(MqttServerClient client) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (_disposed) return false;
      final state = client.connectionStatus?.state;
      if (state == MqttConnectionState.connected) return true;
      final waiting =
          _busy(client) ||
          (client.autoReconnect && state == MqttConnectionState.disconnected);
      if (!waiting) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return client.connectionStatus?.state == MqttConnectionState.connected;
  }

  void _dropClient(MqttServerClient client) {
    _updatesSub?.cancel();
    _updatesSub = null;
    _subscribedTopic = null;
    try {
      client.autoReconnect = false;
      client.disconnect();
    } catch (error) {
      _log('MQTT client cleanup failed: $error');
    }
    if (identical(_client, client)) _client = null;
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

  static String _newSessionSuffix() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 20).toRadixString(36)}';

  void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
