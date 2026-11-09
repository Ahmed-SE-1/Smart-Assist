# Stage 3 deployment and integration checklist

No resource has been deployed by this change. This checklist is not evidence that Firebase, Cloudflare, EMQX, or hardware connectivity has passed.

## Cloudflare account and Worker URL

1. Sign in to the intended Cloudflare account and open **Workers & Pages**.
2. Confirm the account's `workers.dev` subdomain under **Workers & Pages → Settings → Domains & Routes** (dashboard wording may vary). Do not derive or guess it from the Worker name.
3. Record the verified URL. `wrangler.toml` intentionally has no `account_id` or custom route.
4. In a trusted developer shell, authenticate Wrangler with `npx wrangler login` and confirm `npx wrangler whoami` reports the intended account.

## Firebase project and IAM

1. Verify `smartassist-18d2a` is the intended Firebase project before selecting it in a dashboard. This ID came from repository configuration; it does not mean a live project was accessed.
2. In Google Cloud Console, select that project. Confirm Firestore, Identity Toolkit/Identity Platform APIs and billing requirements with the project owner before enabling or changing anything.
3. Create a dedicated service account for the Worker. Grant only Firestore get/list/create/update and Firebase Auth get/create/update permissions. Inspect each permission in IAM and scope roles as narrowly as Google supports; do not use broad Owner/Editor roles.
4. The Worker uses service-account JWT bearer exchange and reads the private key only from encrypted `GOOGLE_SERVICE_ACCOUNT_JSON`. In Cloudflare, open **Workers & Pages → smartassist-api → Settings → Variables and Secrets → Add → Secret** and configure it separately for each environment. Never add the value to Wrangler vars, `.dev.vars.example`, or source.
5. Add `FIREBASE_WEB_API_KEY` as a secret binding. It is a public project identifier, not an admin credential.
6. Verify Auth lookup/create/update/custom-token sign-in using a dedicated staging controller. Verify Firestore transactional reads and writes only against staging documents.
7. Keyless Cloudflare-to-Google Workload Identity Federation is not implemented or proven. Do not describe this as a keyless deployment. Replace the adapter only after an actual issuer/subject trust configuration has been tested.

## Worker staging deployment

1. Install Wrangler in this Worker project with `npm install`; run `npx wrangler whoami` to verify the account.
2. Confirm the configured Firebase project ID with the project owner. Set a staging environment and request-size limits before deployment.
3. Run `npm test`, `npm run typecheck`, and `npm run build` (Wrangler dry-run). Review the resulting bundle and bindings.
4. Configure staging secrets with `npx wrangler secret put GOOGLE_SERVICE_ACCOUNT_JSON --env staging` and `npx wrangler secret put FIREBASE_WEB_API_KEY --env staging`. The current Wrangler file does not yet define a staging block; add and review one against the actual Cloudflare account before these commands. Never paste secret values into logs.
5. After separate approval, run `npx wrangler deploy --env staging` and confirm the returned hostname is the account's verified subdomain.
6. Check `https://<verified-staging-host>/health`; it returns only `{ "ok": true }`. This checks routing only.
7. Test a staging Owner pairing-session create and denial cases, claim, recovery, replay rejection, and Firestore state. These tests require actual staging credentials and are not completed here.

## EMQX and Cron

1. In EMQX Dashboard, identify the exact cluster/region and whether the plan supports authenticated HTTPS publish. Do not use an MQTT listener URL as an HTTPS endpoint.
2. Verify the HTTP API URL, TLS chain, authentication, publish schema and permissions for this specific deployment.
3. Create a dedicated publisher identity restricted to `smartassist/{houseId}/controllers/{controllerId}/control`, with publish permission only.
4. Implement and stage-test the HTTP adapter for denied publish, timeout, rate limiting and retry. Until this exists, `UnconfiguredMqttTransport` fails closed and Worker unpair requests remain pending. Do not enable production unpair cutover.
5. In **Workers & Pages → smartassist-api → Settings → Triggers → Cron Triggers**, verify the one-minute schedule for the selected environment; test retries/expiry against staging operations.

## Flutter configuration

1. Flutter uses `MainControllerWorkerClient` for pairing session and unpair request/status/retry. Firestore status streams, rules and direct Firestore registration remain unchanged.
2. Build staging with `--dart-define=SMARTASSIST_WORKER_BASE_URL=https://<verified-staging-host>`. No define means requests fail closed with `worker-not-configured`.
3. Test ID-token attachment, one forced refresh after HTTP 401, pairing success/denial, polling and retry against staging. Do not log Authorization headers or pairing/token response bodies.
4. Roll back by restoring the Firebase Callable service provider and rebuilding. Keep Functions deployed and avoid letting old and new clients mutate the same live unpair operation during cutover.
5. Mobile app `MqttConfig` no longer reads broker username/password from `MQTT_USERNAME`/`MQTT_PASSWORD` dart-defines. Direct MQTT command publishing therefore fails closed in a production build without injected test-only config. A Worker-authorized owner command/publish route and project-specific EMQX HTTPS transport are required before relay commands can be restored securely; do not pass shared broker credentials to the app.

## Main ESP32 configuration

1. Provision Wi-Fi using the approved ESP32 SDK Wi-Fi provisioning path. Firmware calls `WiFi.begin()` to use the SDK's saved configuration; this change does not implement a new BLE Wi-Fi provisioning flow.
2. Enter the verified URL at `idf.py menuconfig → SmartAssist security → SmartAssist Worker HTTPS base URL`. Keep HTTPS certificate verification enabled and validate the actual Worker certificate chain on target hardware.
3. Production pairing credentials remain gated by protected NVS. Development Mode keeps refresh/recovery credentials in RAM only. Do not enable Flash Encryption/Secure Boot or modify eFuses.
4. MQTT credentials are no longer compiled into the sketch. Production reads `mqtt_user` and `mqtt_pass` from protected NVS, but this repository has no per-device credential provisioning/issuance implementation yet. A fresh device without those values will not connect to MQTT, so relay and event flows remain unavailable. Do not insert arbitrary NVS values or reuse the former shared identity.
5. After an ESP-IDF build succeeds, use a dedicated staging controller and broker. No hardware was flashed or changed by this work.

## Credential rotation and cutover

Wi-Fi and EMQX values formerly in source should be considered exposed. The authorized owner must rotate them in router and EMQX dashboards; removing source literals does not rotate credentials. Revoke the old shared EMQX identity only after a per-device credential path and ACL work. Check git history, previous build artifacts and released firmware before distribution.

Before production cutover require real staging Firebase/Auth/Firestore tests, a verified EMQX HTTPS adapter and ACL, Flutter/firmware integration tests, successful ESP-IDF build, certificate-chain testing on target silicon, rollback app build, Firestore-rule compatibility review, and explicit operator approval. Keep Firebase Functions available through the rollback window.
