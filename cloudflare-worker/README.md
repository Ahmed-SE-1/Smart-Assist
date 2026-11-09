# SmartAssist Cloudflare Worker migration

This Worker is an isolated backend port. The Firebase Functions implementation remains intact as the rollback path. No Worker deployment or live Firebase change was made. Flutter source now has an HTTP client for pairing and unpair routes, but the Worker base URL is unset unless supplied by build configuration; the app therefore does not silently call an undeployed Worker.

## Architecture

`src/index.ts` is a versioned HTTP router and Cron handler. Firebase ID tokens are verified against Google's rotating Secure Token RS256 certificates. Privileged owner/device requests perform an Auth `accounts:lookup` check against `validSince` and disabled status; this is a revocation-aware lookup and adds a Google API request. The token verifier alone checks signatures and standard claims and cannot detect revocation.

Pairing domain logic is imported from `functions/src/controller_pairing.ts` without modifying or deleting it. Firestore REST transactions adapt its transaction interface and preserve the domain's owner/House, one-time token, expiry, assignment and replay checks. Firebase Admin Auth operations use Identity Toolkit administrative REST calls and sign Firebase custom tokens using the service account private key held in an encrypted Worker secret. Controller claims and deterministic UID remain unchanged.

Health is `GET /health` and returns only `{ "ok": true }`. JSON body limit defaults to 16 KiB (configurable from 1 to 64 KiB). CORS is off unless `CORS_ALLOWED_ORIGINS` is configured with exact comma-separated origins; native Flutter requests do not need CORS.

## Routes

All routes use JSON and `Cache-Control: no-store`. Owner routes require `Authorization: Bearer <Firebase ID token>`, and the Worker independently checks revocation and approved Owner/House ownership.

| Method and route | Authentication | Purpose |
|---|---|---|
| `POST /v1/controller/pairing-sessions` | Approved owner ID token | Body `{ "houseId": string }`; returns the one-time token and 5-minute expiry. Only its hash is persisted. |
| `POST /v1/controller/claims` | Pairing capability | Body `{ "token": string, "controllerId": string, "recoverySecret": string }`; claim and provision deterministic device identity. |
| `POST /v1/controller/credentials/recover` | Recovery capability | Body `{ "recoverySecret": string, "controllerId": string }`; re-provision only the bound generation. |
| `POST /v1/controller/unpair-operations` | Approved owner ID token | Body `{ "houseId": string, "controllerId": string }`; starts durable two-phase unpair. |
| `GET /v1/controller/unpair-operations/{id}` | Approved owner ID token | Owner-only operation status. |
| `POST /v1/controller/unpair-operations/{id}/retry` | Approved owner ID token | Retry durable delivery. |
| `POST /v1/controller/unpair-operations/{id}/prepared` | Main Controller ID token | Body `{ "controllerId": string }`; validates device UID, custom claims, generation, assignment and token age. |
| `POST /v1/controller/unpair-operations/{id}/completed` | Main Controller ID token | Same device checks; clears assignment only after prepared state. |

Errors return `{ "error": { "code": string, "message": string } }` with standard 400, 401, 403, 404, 409, 412, 413, 429, 503, or 500 status codes. Pairing and recovery capabilities are sensitive inputs and are never logged. A claim can persist its assignment before Auth provisioning, matching the current Functions partial-failure recovery pattern; the device must call recovery using the original short-lived recovery secret if provisioning fails.

## Firebase and Google prerequisites

`FIREBASE_PROJECT_ID` is read from repository configuration (`smartassist-18d2a`). Set it in Wrangler configuration and verify it against the Firebase project before deployment. The Worker service identity needs narrowly scoped Firestore document read/write access to the collections used by pairing and unpair, plus Identity Platform/Firebase Auth permissions to look up, create, update users and set custom claims. Required operations use Identity Toolkit `projects.accounts:lookup`, `projects.accounts`, and `projects.accounts:update`. The public Firebase Web API key is configured as `FIREBASE_WEB_API_KEY` for Identity Toolkit calls; it is not an admin credential.

No Cloudflare-to-Google Workload Identity Federation trust configuration or Cloudflare runtime attestation was found in the repository, and no Google/Cloudflare dashboard access was available to prove a keyless exchange. Therefore keyless WIF is unverified here. The adapter uses a tightly scoped service account private key held only as encrypted `GOOGLE_SERVICE_ACCOUNT_JSON`; do not create or commit a key as part of this migration. If a supported WIF issuer and subject-token exchange are configured later, replace `GoogleAdminAuth` behind its adapter and remove this secret. Grant only the service account permissions needed for Firestore document read/query/create/update in the pairing collections (`datastore.entities.get`, `datastore.entities.list`, `datastore.entities.create`, `datastore.entities.update`) and Firebase Auth user lookup/create/update (`firebaseauth.users.get`, `firebaseauth.users.create`, `firebaseauth.users.update`). These should be scoped at the Firebase project/database boundary available to IAM; Firestore Rules do not constrain service-account Admin REST access. The project owner must verify the current IAM role composition, Firestore/Identity Toolkit APIs, and billing plan before deployment; none were changed or live-verified here.

## Cloudflare local setup

The Worker has no account ID, custom domain, or `workers.dev` subdomain hard-coded. Wrangler's generated URL depends on the actual account. `wrangler.toml` uses repository project ID, development/production environments, and a one-minute Cron Trigger. Configure secrets with `wrangler secret put GOOGLE_SERVICE_ACCOUNT_JSON` and `wrangler secret put FIREBASE_WEB_API_KEY`; use `.dev.vars` only for local development. `.dev.vars.example` contains placeholders, not usable credentials. Confirm the production environment's secret bindings and Cron Trigger in the Cloudflare dashboard before deployment.

Install the local Wrangler CLI with `npm install`, then use `npm run dev` for local Worker development or `npm run build` for a non-deploying Wrangler compile. Do not use a normal `wrangler deploy` until the external prerequisites and explicit deployment approval are handled.

Run local checks from this directory:

```powershell
npm test
npm run typecheck
```

Tests use Node's built-in test runner and generated local RSA keys/mocks. They prove local validation and domain behavior only; they are not Firebase, Google IAM, Firestore, Auth Admin, Cloudflare, or EMQX integration tests.

## EMQX and Cron boundary

Existing Functions publish to `smartassist/{houseId}/controllers/{controllerId}/control` with QoS 1 and non-retained JSON `{v:1,type:"unpair",phase,operationId,houseId,controllerId,expiresAt}`. The Worker preserves that topic and payload. Repository source does not contain a verified project-specific EMQX HTTP API host/auth scheme, and no dashboard credentials were available. `UnconfiguredMqttTransport` therefore fails closed. Failed sends update durable retry metadata and never mark an operation completed. A real EMQX HTTP adapter must be implemented only after confirming the broker deployment, HTTP API endpoint, authentication mechanism, TLS requirements, and dashboard authorization. The mock transport interface is covered in tests.

The Cron handler checks pending/prepared operations due for delivery and expires overdue unprepared operations through the same domain transitions. Because the current transport is unconfigured, delivery remains pending with retry backoff. Prepared operations are not released by a failed send.

## Intentionally not migrated

Legacy/unused exports remain in Firebase Functions: `healthCheck` (a separate authenticated callable, while Worker has an HTTP health route), `createControllerIdentityMigrationSession`, `provisionExistingMainControllerIdentity`, `unpairMainController` compatibility alias, `registerOwner`, `registerMember`, `ensureOwnerIndexes`, and `migrateLegacyHouses`. The legacy controller identity migration path is excluded from the requested active pairing/claim/recovery operations. Registration remains Flutter's current direct Firestore flow. Firebase Functions source and deployment configuration were left intact for rollback.

## Rollback and remaining integration work

Rollback requires no data migration: the Worker has not been deployed and Firebase Functions remains intact. Rebuild Flutter with the prior Callable service provider to roll back. Keep both backends from mutating the same production operation during cutover; first deploy and integration-test the Worker in a staging Firebase project and separate EMQX staging broker, then switch clients deliberately. Flutter pairing and unpair routes use a build-configured HTTPS base URL and send Firebase ID tokens only on owner routes; claim/recovery device capabilities remain separate. Add real staging Flutter and device-level BLE/ESP32 tests before production cutover.

Remaining blockers are service-account secret provisioning and IAM/API/billing verification, actual EMQX endpoint/auth verification and HTTP transport implementation, Cloudflare account/subdomain selection, staging integration tests, and a secure Worker-backed Flutter command publishing route.

## Stage 3 client and device integration

Flutter now uses `MainControllerWorkerClient` for pairing-session creation and owner unpair operations. Configure the app at build time with `--dart-define=SMARTASSIST_WORKER_BASE_URL=https://<verified-worker-host>` after the real Worker is deployed and its project/IAM bindings are verified. An unset value fails closed. The client fetches the signed-in Firebase ID token, refreshes it once after HTTP 401, and never logs request/response secrets. Flutter continues to read House/controller status from Firestore and keeps its existing direct Firestore registration flow. Keep Firebase Functions untouched for rollback.

The Main ESP32 uses `/v1/controller/claims`, `/v1/controller/credentials/recover`, and `/v1/controller/unpair-operations/{id}/prepared|completed` with the existing Firebase device ID token for acknowledgements and capability bodies for claim/recovery. Configure `SMARTASSIST_WORKER_BASE_URL` through the IDF menuconfig Kconfig entry before building; it must be the verified `https://` Worker origin. The firmware keeps certificate validation enabled and retains its existing BLE UUIDs and pairing JSON. Development Mode still does not persist credentials. No firmware was flashed.

Firmware no longer contains Wi-Fi passwords or a shared MQTT username/password. Wi-Fi uses the ESP32 SDK-provisioned station configuration (`WiFi.begin()` without source literals); provision the network through the approved device provisioning procedure and never add the password back to source. Production reads MQTT credentials from protected NVS keys `mqtt_user` and `mqtt_pass`. The current repository does not implement a secure per-device MQTT credential provisioning/rotation flow, and the Worker does not yet issue EMQX credentials; until that provisioning and least-privilege ACL are delivered, Main ESP32 MQTT remains intentionally unavailable. This means normal relay/event MQTT behavior is not operational on a newly built device with empty protected credential slots. Do not reuse a shared mobile or firmware credential. The existing MQTT broker host and TLS root are unchanged.

Before a device build, inspect menuconfig and confirm Production encrypted-NVS capability is selected and that Flash Encryption/Secure Boot/eFuse settings are untouched. In Development Mode the controller cannot perform durable unpair recovery; keep that explicit behavior. To enable actual Worker calls, first build/deploy only to a staging Firebase project and Cloudflare Worker, configure the URL in Flutter and firmware, validate TLS from the device, then run claim/recovery and two-phase unpair against a staging controller. Existing Flutter direct Firestore status streams/rules must also be deployed and verified independently. Do not switch production clients while Worker EMQX delivery is unconfigured.

Credential hygiene: Wi-Fi and EMQX values previously embedded in firmware source should be considered exposed and rotated through the router/EMQX dashboard by the owner; source removal does not rotate them. Revoke the old shared EMQX identity after a new per-controller issuance path and ACL are operational. Check repository history and release binaries before public distribution. No live credential rotation was performed.
