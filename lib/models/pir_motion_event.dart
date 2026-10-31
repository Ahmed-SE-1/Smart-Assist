import 'dart:convert';

import 'room.dart';

/// A PIR event published by the Main ESP32, if the firmware sends one.
///
/// This repository does not contain that firmware. [tryParse] accepts only the
/// proposed contract and returns null for anything else.
class PirMotionEvent {
  const PirMotionEvent({
    required this.houseId,
    required this.mqttNodeId,
    required this.lightOn,
    required this.eventName,
  });

  static const motionEvent = 'motion';
  static const motionTimeoutEvent = 'motion_timeout';

  final String houseId;
  final String mqttNodeId;
  final bool lightOn;
  final String eventName;

  static final _topic = RegExp(r'^smartassist/([^/]+)/([^/]+)/events$');

  /// Returns null when the topic, house, node, or JSON does not match.
  static PirMotionEvent? tryParse({
    required String topic,
    required String payload,
    required String expectedHouseId,
  }) {
    final house = expectedHouseId.trim();
    if (house.isEmpty) return null;
    final match = _topic.firstMatch(topic.trim());
    if (match == null) return null;
    final topicHouse = match.group(1)!;
    final nodeId = match.group(2)!;
    if (topicHouse != house || !Room.isSupportedMqttNodeId(nodeId)) {
      return null;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final event = decoded['event']?.toString();
    final sensor = decoded['sensor']?.toString();
    final device = decoded['device']?.toString();
    final state = decoded['state']?.toString();
    if (sensor != 'PIR' || device != 'light') return null;

    if (event == motionEvent && state == 'ON') {
      return PirMotionEvent(
        houseId: topicHouse,
        mqttNodeId: nodeId,
        lightOn: true,
        eventName: event!,
      );
    }
    if (event == motionTimeoutEvent && state == 'OFF') {
      return PirMotionEvent(
        houseId: topicHouse,
        mqttNodeId: nodeId,
        lightOn: false,
        eventName: event!,
      );
    }
    return null;
  }
}

/// SnackBar copy for one accepted PIR transition.
class PirAutomationNotice {
  const PirAutomationNotice({
    required this.title,
    required this.message,
    required this.roomId,
    required this.deviceId,
  });

  final String title;
  final String message;
  final String roomId;
  final String deviceId;

  static PirAutomationNotice forRoom({
    required String roomId,
    required String roomName,
    required String deviceId,
    required bool lightOn,
  }) {
    if (lightOn) {
      return PirAutomationNotice(
        title: 'Automatic Light Activation',
        message: '$roomName Light turned ON due to PIR motion detection.',
        roomId: roomId,
        deviceId: deviceId,
      );
    }
    return PirAutomationNotice(
      title: 'Automatic Light Off',
      message: '$roomName Light turned OFF after motion timeout.',
      roomId: roomId,
      deviceId: deviceId,
    );
  }
}
