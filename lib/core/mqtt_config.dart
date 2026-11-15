/// MQTT configuration for the original direct-to-EMQX device-control path.
///
/// Direct credentials may be supplied only to local debug runs. They are
/// compiled into the debug application and must never be used for a
/// distributable/release build. Production builds fail closed until the app
/// has a broker authorization flow that does not embed a shared credential.
class MqttConfig {
  const MqttConfig({
    bool? enabled,
    this.host = const String.fromEnvironment('MQTT_HOST'),
    this.port = const int.fromEnvironment('MQTT_PORT', defaultValue: 8883),
    this.username = const String.fromEnvironment('MQTT_USERNAME'),
    this.password = const String.fromEnvironment('MQTT_PASSWORD'),
    this.clientId = const String.fromEnvironment('MQTT_CLIENT_ID'),
    this.caAsset = const String.fromEnvironment(
      'MQTT_CA_ASSET',
      defaultValue: 'assets/certs/emqx_ca.crt',
    ),
    this.testAppDeviceId = const String.fromEnvironment(
      'MQTT_TEST_APP_DEVICE_ID',
    ),
    this.testMqttDeviceId = const String.fromEnvironment(
      'MQTT_TEST_MQTT_DEVICE_ID',
      defaultValue: String.fromEnvironment('MQTT_TEST_DEVICE_ID'),
    ),
    this.testChannel = const int.fromEnvironment('MQTT_TEST_CHANNEL'),
  }) : enabled =
           enabled ??
           const bool.fromEnvironment(
             'MQTT_ENABLED',
             defaultValue: bool.fromEnvironment(
               'MQTT_ENABLE_REAL_TEST',
               defaultValue: false,
             ),
           );

  final bool enabled;
  final String host;
  final int port;
  final String username;
  final String password;
  final String clientId;
  final String caAsset;
  final String testAppDeviceId;
  final String testMqttDeviceId;
  final int testChannel;

  String? get connectionError {
    if (enabled &&
        (const bool.fromEnvironment('dart.vm.product') ||
            const bool.fromEnvironment('dart.vm.profile'))) {
      return 'Direct MQTT credentials are disabled outside local debug builds.';
    }
    if (host.trim().isEmpty) return 'MQTT host is not configured.';
    if (port < 1 || port > 65535) return 'MQTT port is invalid.';
    if (username.trim().isEmpty || password.isEmpty) {
      return 'MQTT username or password is not configured.';
    }
    if (caAsset.trim().isEmpty) {
      return 'MQTT CA certificate still needs to be supplied.';
    }
    return null;
  }

  String? get mappingError {
    if (testAppDeviceId.trim().isEmpty ||
        testMqttDeviceId.trim().isEmpty ||
        testChannel < 0 ||
        testChannel > 2) {
      return 'MQTT test device mapping is not configured.';
    }
    return null;
  }
}
