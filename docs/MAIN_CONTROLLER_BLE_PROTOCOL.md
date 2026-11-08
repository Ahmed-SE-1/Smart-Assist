# Main Controller BLE Pairing Protocol (Phase 3A)

This protocol is implemented in Flutter. The ESP32 firmware is not in this
repository and must implement the same GATT service before pairing can work on
hardware.

## BLE GATT

Use a custom 128-bit service, advertised while the Main ESP32 is in pairing
mode:

| Item | UUID | Properties |
| --- | --- | --- |
| Main Controller pairing service | `9b0a1000-6f2a-4d71-9c3e-2a4b5c6d7e80` | Advertise this service |
| Pairing request | `9b0a1001-6f2a-4d71-9c3e-2a4b5c6d7e80` | Write with response |
| Pairing result | `9b0a1002-6f2a-4d71-9c3e-2a4b5c6d7e80` | Notify or indicate |

The app scans only for the service UUID. It verifies both characteristics
before writing. The app requests an ATT MTU of 185; the firmware must support a
GATT long write for the request and deliver the complete result JSON in a
notification/indication. The implementation waits up to 45 seconds for a
result, bounded by the pairing session's five-minute expiry.

## BLE request / response

The app writes this UTF-8 JSON to the Pairing request characteristic:

```json
{"v":1,"token":"<43-character-base64url-token>"}
```

The raw token exists only in app memory and the active BLE write. Firmware
must not print or persist it. The device derives a stable controller identity
from hardware identity, in the backend-accepted form `CTRL_` followed by 8–56
letters, digits, `_` or `-`; a MAC address by itself is not proof of
authorization.

On success, firmware sends the actual backend claim result in this BLE JSON:

```json
{"v":1,"ok":true,"result":{"houseId":"<house-id>","controllerId":"CTRL_<stable-id>","status":"paired"}}
```

On failure, send an error without the token or sensitive details:

```json
{"v":1,"ok":false,"error":{"code":"permission-denied"}}
```

The app shows success only if the BLE response has `ok: true`, matches the
current House ID and controller ID format, and Firestore confirms both
`houses/{houseId}.mainControllerId` and
`controllers/{controllerId}.activeHouseId`. The app never calls the claim
function itself.

## ESP32 HTTPS callable

The deployed source defines `claimMainController` as an `https.onCall`
function. The Functions source has no explicit region setting, so it uses the
default `us-central1` region. For Firebase project `smartassist-18d2a`, the
callable URL is:

`https://us-central1-smartassist-18d2a.cloudfunctions.net/claimMainController`

Make an HTTPS `POST` with `Content-Type: application/json` and the Firebase
callable envelope. Do not include a client-supplied House ID:

```json
{"data":{"token":"<pairing-token>","controllerId":"CTRL_<stable-id>"}}
```

Successful callable result (the callable protocol wraps the function's return
value):

```json
{"result":{"houseId":"<house-id>","controllerId":"CTRL_<stable-id>","status":"paired"}}
```

Callable errors use the Firebase envelope, for example:

```json
{"error":{"status":"PERMISSION_DENIED","message":"Pairing token is invalid or expired."}}
```

The claim callable does not require a Firebase Auth token from the ESP32; the
short-lived token is its bearer authorization. Firmware must use normal TLS
certificate validation and must not log the request token. It should pass the
successful `result` object through as the BLE success response and map an
`error.status` to the BLE error `code`. This pairing token proves possession of
the app-created session, not the hardware's physical identity.

The Flutter callable client explicitly targets `us-central1`. No Functions or
Rules deployment is performed by this phase.
