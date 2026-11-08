# MQTT authorization status

Phase 2.1 reviewed the Flutter repository only. No broker configuration or Main
ESP32 firmware source is present in this repository, so the deployed broker
ACLs and firmware credentials cannot be established here.

## Flutter credentials and topics

`lib/core/mqtt_config.dart` reads `MQTT_USERNAME` and `MQTT_PASSWORD` from
Flutter compile-time definitions (along with host, port and client ID). These
values are supplied to the MQTT client at runtime. Any values embedded through
`--dart-define` are recoverable from a distributed application and must not be
treated as durable secrets. This report does not print configured values.

`lib/services/mqtt_service.dart` authenticates with those shared configured
credentials. It constructs command and event topics using the existing
`smartassist/{houseId}/{nodeId}/cmd` and
`smartassist/{houseId}/{nodeId}/events` format. Flutter code selecting a
House-scoped topic is not itself a broker authorization boundary.

## Main ESP32 and broker status

There are no Main ESP32 firmware files or EMQX/broker ACL configuration in the
Flutter project. Therefore the firmware username/password, actual topic
permissions, and whether the broker enforces House-scoped ACLs are unknown and
unverified. Do not treat MQTT authorization as fixed based on this change.

## Pending member access and required enforcement

The app now directs unapproved members to the pending-approval screen, suppresses
PIR event subscription for them, and prevents MQTT device commands through the
Flutter device provider. This is a client-side guard. Anyone holding the shared
broker credentials can bypass the app, so the broker must deny device command
publishes independently.

Before production provisioning, configure a trusted backend to authenticate
Firebase identity and current House approval, then issue short-lived,
revocable MQTT credentials or tokens scoped to that user's House and required
topics. Broker ACLs should restrict command publishing and event subscription
to the approved House and required node paths, and revoke access when approval
is removed. Do not provide MQTT administrative credentials to the app. App
Check can be defense in depth but cannot replace this broker-side authorization.

Join-code attempts also need server-side rate limits and abuse monitoring.
Reliable enforcement requires an operational rate-limiting store or gateway;
this repository does not implement one.
