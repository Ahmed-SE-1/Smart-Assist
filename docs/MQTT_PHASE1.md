# MQTT device commands

Real MQTT is disabled by default. With `MQTT_ENABLED=true`, a fan or light
ON/OFF command is published only when its room has `ROOM1_NODE` or
`ROOM2_NODE` and the device channel matches the firmware mapping (fan `1`,
light `2`). AC, sensors, fan speed, and AC temperature stay on the simulator.
An unmapped room is not published to a guessed node.

Assign the node from Add Room or Edit Room. Fan and light channels are set
from the device type when the device is saved.

Run with values supplied outside source control:

```powershell
flutter run --dart-define=MQTT_ENABLED=true --dart-define=MQTT_HOST=<BROKER_HOST> --dart-define=MQTT_PORT=8883 --dart-define=MQTT_USERNAME=<USERNAME> --dart-define=MQTT_PASSWORD=<SECRET>
```

`MQTT_TEST_APP_DEVICE_ID`, `MQTT_TEST_MQTT_DEVICE_ID`, and `MQTT_TEST_CHANNEL`
remain a fallback for one light that has no saved channel and whose room has
no node. They do not override a room or device mapping. `MQTT_TEST_CHANNEL`
must be `2` for that light, and the test node must be `ROOM1_NODE` or
`ROOM2_NODE`. `MQTT_ENABLE_REAL_TEST` and `MQTT_TEST_DEVICE_ID` remain
supported as legacy define names.

The registered `assets/certs/emqx_ca.crt` asset is used by default. Override
its path with `MQTT_CA_ASSET` only when needed. TLS certificate validation is
never disabled.

On the broker machine, inspect commands with:

```sh
mosquitto_sub -h 127.0.0.1 -p 8883 --cafile <CA_FILE> -u <USERNAME> -P '<SECRET>' -t 'smartassist/+/+/cmd' -q 1 -v
```

The payload contains only `cmdId`, `channel`, and `state`. QoS is 1 and retain
is false. A queued publish is not an ESP32 acknowledgement.

## Proposed PIR events

The Flutter app subscribes, on the same TLS client, to:

`smartassist/{HOUSE_ID}/+/events`

A motion event the app will accept:

```json
{
  "event": "motion",
  "sensor": "PIR",
  "device": "light",
  "state": "ON",
  "reason": "motion"
}
```

A timeout event:

```json
{
  "event": "motion_timeout",
  "sensor": "PIR",
  "device": "light",
  "state": "OFF",
  "reason": "motion_timeout"
}
```

`{ROOM_NODE}` is `ROOM1_NODE` or `ROOM2_NODE`. No firmware in this repository
publishes these messages. Until the Main ESP32 does, the app cannot show a
live PIR update.
