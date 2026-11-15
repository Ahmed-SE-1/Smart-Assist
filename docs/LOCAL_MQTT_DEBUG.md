# Local MQTT debug run

The Flutter app publishes directly to EMQX only when local debug configuration is supplied. The default remains disabled. `MqttConfig` rejects direct MQTT in Flutter profile and release builds because the broker credential would otherwise be extractable from the packaged app.

1. Copy `mqtt.local.example.json` to the ignored root file `mqtt.local.json`.
2. Replace only the local password placeholder with the project owner's existing development MQTT password. Do not commit or print that file. Do not share a built APK containing the shared account credential.
3. From a Windows CMD opened at the project root, run:

   ```cmd
   flutter run --dart-define-from-file=mqtt.local.json
   ```

The command keeps the password out of the command text and shell history. Flutter still embeds the values in the local debug build. This is a controlled developer test route, not production-safe credential delivery. The broker account is shared, so the app's House/member checks are not broker-enforced topic ACLs; release builds stay blocked until a per-user/device authorization mechanism exists.

The direct client uses TLS with `assets/certs/emqx_ca.crt`, broker port 8883, MQTT 3.1.1, a per-process unique client ID, QoS 1 non-retained command publishes, and House-scoped subscriptions for PIR events and Main Controller availability. Commands use the original JSON shape `{"channel":1,"state":"ON"}` and topics `smartassist/{houseId}/{ROOM1_NODE|ROOM2_NODE}/cmd`. Channel `0` addresses Fan + Light, `1` Fan, and `2` Light. Publishing confirmation means only that the local MQTT client queued the packet. The firmware protocol currently has no relay acknowledgement, so the app shows MQTT requests as pending and does not save them as confirmed relay state.

## Hardware limits

This config only restores the Flutter publisher. The checked-in MainController firmware still requires `mqtt_user` and `mqtt_pass` from protected NVS and leaves them empty in Development Mode. The current `sdkconfig` has Development Mode enabled and does not enable NVS encryption or flash encryption. There is no safe local command to provision these values on this board without first approving and completing secure storage provisioning. Do not put the app's shared credential into firmware or ordinary NVS. Actual controller/Node control remains blocked until secure controller credentials are provisioned and both Node firmware projects are available for protocol verification. No broker connection or physical actuation is claimed by this documentation.
