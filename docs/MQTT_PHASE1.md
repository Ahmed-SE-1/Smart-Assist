# MQTT Phase 1

Real MQTT is disabled by default. Only the explicitly mapped **light** uses
real TLS MQTT for `ON` and `OFF`; fan/AC actions and every other device retain
their simulation behaviour.

Run with values supplied outside source control:

```powershell
flutter run --dart-define=MQTT_ENABLE_REAL_TEST=true --dart-define=MQTT_HOST=<BROKER_LAN_IP> --dart-define=MQTT_PORT=8883 --dart-define=MQTT_USERNAME=<USERNAME> --dart-define=MQTT_PASSWORD=<SECRET> --dart-define=MQTT_CA_ASSET=<CA_ASSET_PATH> --dart-define=MQTT_TEST_APP_DEVICE_ID=<APP_LIGHT_ID> --dart-define=MQTT_TEST_DEVICE_ID=<BROKER_DEVICE_ID> --dart-define=MQTT_TEST_CHANNEL=1
```

Add the real private-CA certificate asset yourself and register it in
`pubspec.yaml`; no fake certificate is included. TLS certificate validation is
never disabled.

On the broker machine, inspect commands with:

```sh
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile <CA_FILE> -u <USERNAME> -P '<SECRET>' -t 'smartassist/+/+/cmd' -q 1 -v
```

The payload contains only `cmdId`, `channel`, `state`, and Unix-seconds `ts`.
QoS is 1 and retain is false. Phase-1 success is a broker-accepted publish;
there is no ESP32 acknowledgement yet.
