# Main Controller device identity provisioning (Phase 2)

This phase provisions Firebase Auth identities from trusted Cloud Functions. It
does not modify firmware, MQTT, ESP-NOW, PIR, room assignments, House IDs, or
the BLE service/characteristic UUIDs.

## Identity and registry

New controller IDs are `CTRL_` followed by the lowercase 12-hex-digit stable
ESP32 eFuse/base MAC (for example `CTRL_001122aabbcc`). The claim callable
validates this shape. A controller Firebase Auth UID is deterministically
`smartassist-controller-{controllerId}`. The backend derives the House only
from the stored pairing session; no claim or migration device request can
select a House.

`controllers/{controllerId}` stores only identity metadata:

- `firebaseAuthUid`
- `authCredentialGeneration`
- `authCredentialStatus`: `provisioning`, `active`, or `revoked`
- `authCredentialIssuedAt`, `authCredentialRevokedAt`

No custom token, refresh token, password, or backend secret is stored in
Firestore. Registry writes stay in Admin SDK Cloud Functions; client rules
remain deny-write for controllers and pairing/migration sessions.

## Normal pairing provisioning

The existing Flutter BLE request remains exactly `{"v":1,"token":"…"}` and
the BLE UUIDs and BLE success result are unchanged. The ESP32 makes the
existing callable request to `claimMainController` with Firebase callable
envelope `{ "data": { "token": "<pairing-token>", "controllerId":
"CTRL_<12 lowercase hex>" } }`. It must not send a House ID.

On success, callable `result` retains `houseId`, `controllerId`, and `status`
and adds:

```json
{
  "deviceCredential": {
    "customToken": "<Admin SDK minted Firebase custom token>",
    "authUid": "smartassist-controller-CTRL_001122aabbcc",
    "credentialGeneration": 1
  }
}
```

This credential is an HTTPS response extension only. Firmware exchanges the
custom token using Firebase Auth `accounts:signInWithCustomToken` with the
project's public Firebase Web API key, receives an ID token and refresh token,
then stores the refresh token in protected device storage (encrypted NVS / flash
encryption). It must not persist the short-lived custom token. It should send
the existing BLE success notification only after Firebase token exchange and
secure persistence succeed. The BLE response remains the current Flutter
contract, e.g. `{ "v":1,"ok":true,"result":{"houseId":"…",
"controllerId":"CTRL_…","status":"paired"} }`; never pass the custom token
through BLE notifications.

The existing 5-minute pairing token can safely retry a claim after the Firestore
claim committed but the HTTPS result was lost. A retry by the same controller
returns the same assignment and reprovisions the same generation. The backend
marks the credential `provisioning` before Auth mutation and `active` only after
assignment is revalidated. Flutter's current pairing service now requires
active credential metadata as well as both House/controller links before it
reports success.

## Device-authenticated unpair acknowledgement

After exchanging the custom token, the controller calls the existing callable
names `acknowledgeMainControllerUnpairPrepared` and
`acknowledgeMainControllerUnpairCompleted` with Firebase callable envelopes
`{ "data": { "operationId": "…", "controllerId": "CTRL_…" } }` and the
Firebase ID token in the normal callable Authorization header. Acknowledgement
authorization checks all of: deterministic Firebase UID, `deviceType`, exact
controller ID, credential generation, active/revoked state, unexpired token,
token auth time versus Firebase token revocation time, operation controller ID,
and House assignment. A controller cannot acknowledge another controller's
operation or claim a different House.

On completed unpair the transaction clears both registry links and marks the
credential revoked; Functions then revokes refresh tokens and disables the
device Auth user. Completion retries are idempotent for that already-completed
operation. Re-pair increments credential generation and re-enables the same
deterministic UID. Old refresh tokens are revoked, and old ID tokens fail the
registry generation/status and revocation-time checks.

Firmware should refresh the Firebase ID token with its stored refresh token
before expiry. Refresh responses may rotate the refresh token; persist the newest
one atomically. If credential state is revoked or identity calls fail with
permission denied, stop acknowledgements and require owner pairing/migration.

## Existing-controller migration

Existing controller IDs and their House links are preserved. An approved owner
calls `createControllerIdentityMigrationSession` with `{houseId, controllerId}`.
It returns `{houseId, controllerId, expiresAt, token}`; the raw random token is
owner-only and held in memory. For future BLE firmware/app migration support,
the compatible optional v1 request extension is:

```json
{"v":1,"action":"migrateIdentity","token":"<migration-token>","controllerId":"<existing-controller-id>"}
```

The device calls `provisionExistingMainControllerIdentity` with callable data
`{token, controllerId}`. The server consumes the hash-keyed five-minute token,
derives owner and House from that session, rechecks approved ownership and both
registry links, then issues the same `deviceCredential` response extension.
This migration does not modify `houses/{houseId}.mainControllerId`,
`controllers/{controllerId}.activeHouseId`, the House ID, or room assignments.
The existing BLE request is unchanged; legacy firmware will not understand the
optional migration action. A future Flutter migration UI/firmware update is
required to transfer this migration token. No migration UI or firmware was
added here.

## Security limitations and rollout

- A MAC-derived identifier is stable but not cryptographic proof of hardware;
  a malicious device can spoof a MAC. The owner-approved short-lived pairing
  token (or migration token) remains required. Strong hardware proof needs
  secure-element/attestation support not present in this repository.
- Firebase custom tokens are bearer tokens. The claim token is returned only
  to the device's HTTPS callable response; do not log or relay it to Flutter.
  TLS and protected device storage are required.
- The Firebase Web API key used for custom-token exchange is public project
  configuration, not an Admin credential. Admin credentials remain in the
  Functions runtime.
- Existing legacy controllers have no Auth UID/credential fields. They remain
  paired and operational until their owner explicitly initiates the migration
  flow. Do not clear their House ID or ask owners to create a new House.
- No Functions or Firestore Rules deployment was performed. Firmware must
  implement the callable exchange, token refresh/storage, and existing
  acknowledgement calls before this identity can be used on a physical device.
