import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/mqtt_service.dart';

final mqttServiceProvider = Provider<MqttService>((ref) {
  final service = MqttService();
  service.connect();
  ref.onDispose(() => service.dispose());
  return service;
});
