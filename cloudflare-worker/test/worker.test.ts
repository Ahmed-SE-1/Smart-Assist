import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import worker from "../src/index.ts";
import { ApiError } from "../src/errors.ts";
import { FirebaseIdTokenVerifier, clearFirebaseCertCacheForTests } from "../src/firebase-id-token.ts";
import { redactFields } from "../src/logging.ts";
import { acknowledgeMainControllerUnpairCompleted, acknowledgeMainControllerUnpairPrepared, claimMainController, createPairingSession, expireMainControllerUnpair, hashPairingToken, PairingError, recoverMainControllerCredential, requestMainControllerUnpair, validateControllerIdentityClaims } from "../../functions/src/controller_pairing.ts";
import { FirebaseAuthAdmin } from "../src/firebase-auth-admin.ts";
import { UnconfiguredMqttTransport } from "../src/mqtt-adapter.ts";
import { deliverUnpairOperation } from "../src/unpair-delivery.ts";
import { FirestoreRestStore } from "../src/firestore-rest.ts";
import { GoogleAdminAuth } from "../src/google-auth.ts";

const now = Math.floor(Date.now() / 1000);
const project = "smartassist-18d2a";
const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const pem = publicKey.export({ type: "spki", format: "pem" }).toString();
function token(claims: Record<string, unknown> = {}) {
  const enc = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const body = `${enc({ alg: "RS256", kid: "test-key" })}.${enc({ iss: `https://securetoken.google.com/${project}`, aud: project, sub: "owner-1", iat: now, exp: now + 3600, auth_time: now, ...claims })}`;
  return `${body}.${sign("RSA-SHA256", Buffer.from(body), privateKey).toString("base64url")}`;
}
function verifier() {
  clearFirebaseCertCacheForTests();
  return new FirebaseIdTokenVerifier(project, async () => new Response(JSON.stringify({ "test-key": pem }), { headers: { "cache-control": "public, max-age=3600" } }), () => now);
}

test("Firebase ID token accepts valid RS256 and rejects wrong project, issuer, expiry, malformed tokens", async () => {
  assert.equal((await verifier().verify(token())).sub, "owner-1");
  await assert.rejects(verifier().verify(token({ aud: "wrong-project" })), ApiError);
  await assert.rejects(verifier().verify(token({ iss: "https://wrong.example" })), ApiError);
  await assert.rejects(verifier().verify(token({ exp: now - 1 })), ApiError);
  await assert.rejects(verifier().verify("bad.token"), ApiError);
});

test("Firebase ID token rejects invalid signatures and unsupported algorithm", async () => {
  const valid = token().split(".");
  valid[2] = Buffer.from("not-a-signature").toString("base64url");
  await assert.rejects(verifier().verify(valid.join(".")), ApiError);
  const parts = token().split(".");
  const unsupported = `${Buffer.from(JSON.stringify({ alg: "HS256", kid: "test-key" })).toString("base64url")}.${parts[1]}.${parts[2]}`;
  await assert.rejects(verifier().verify(unsupported), ApiError);
});

test("Firebase signing keys are cached and refreshed after unknown kid", async () => {
  clearFirebaseCertCacheForTests();
  let reads = 0;
  const verify = new FirebaseIdTokenVerifier(project, async () => { reads++; return new Response(JSON.stringify({ "test-key": pem }), { headers: { "cache-control": "public, max-age=3600" } }); }, () => now);
  await verify.verify(token()); await verify.verify(token());
  assert.equal(reads, 1);
});

test("Firebase certificate fetch failures are generic and logged without upstream text", async () => {
  clearFirebaseCertCacheForTests();
  const original = console.error; const logs: unknown[][] = []; console.error = (...args: unknown[]) => { logs.push(args); };
  try {
    const secretLike = "s".repeat(48);
    const network = new FirebaseIdTokenVerifier(project, async () => { throw new TypeError(`network ${secretLike}`); });
    await assert.rejects(network.verify(token()), (error: unknown) => error instanceof ApiError && error.message === "Firebase signing keys are temporarily unavailable.");
    clearFirebaseCertCacheForTests();
    const http = new FirebaseIdTokenVerifier(project, async () => new Response("sensitive body", { status: 503 }));
    await assert.rejects(http.verify(token()), ApiError);
    clearFirebaseCertCacheForTests();
    const malformed = new FirebaseIdTokenVerifier(project, async () => new Response("not-json"));
    await assert.rejects(malformed.verify(token()), ApiError);
    assert.equal(JSON.stringify(logs).includes(secretLike), false);
    assert.equal(JSON.stringify(logs).includes("sensitive body"), false);
  } finally { console.error = original; clearFirebaseCertCacheForTests(); }
});

test("Firebase certificate cache expires and refreshes", async () => {
  clearFirebaseCertCacheForTests(); let reads = 0;
  const verify = new FirebaseIdTokenVerifier(project, async () => { reads++; return new Response(JSON.stringify({ "test-key": pem }), { headers: { "cache-control": "public, max-age=1" } }); }, () => now);
  await verify.verify(token()); await verify.verify(token()); assert.equal(reads, 1);
  await new Promise(resolve => setTimeout(resolve, 1100)); await verify.verify(token()); assert.equal(reads, 2);
});

test("Firebase certificates use bounded stale fallback and coalesce concurrent fetches", async () => {
  clearFirebaseCertCacheForTests(); let reads = 0;
  const cached = new FirebaseIdTokenVerifier(project, async () => { reads++; return new Response(JSON.stringify({ "test-key": pem }), { headers: { "cache-control": "max-age=0" } }); }, () => now);
  await cached.verify(token());
  const unavailable = new FirebaseIdTokenVerifier(project, async () => { throw new TypeError("network unavailable"); }, () => now);
  assert.equal((await unavailable.verify(token())).sub, "owner-1");
  clearFirebaseCertCacheForTests(); reads = 0;
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const concurrent = new FirebaseIdTokenVerifier(project, async () => { reads++; await gate; return new Response(JSON.stringify({ "test-key": pem }), { headers: { "cache-control": "max-age=3600" } }); }, () => now);
  const first = concurrent.verify(token()); const second = concurrent.verify(token());
  await Promise.resolve(); release(); await Promise.all([first, second]);
  assert.equal(reads, 1);
  clearFirebaseCertCacheForTests();
});

test("Firebase certificate timeout is classified without logging the thrown message", async () => {
  clearFirebaseCertCacheForTests();
  const original = console.error; const logs: unknown[][] = []; console.error = (...args: unknown[]) => { logs.push(args); };
  try {
    const secretLike = "t".repeat(48);
    const verifier = new FirebaseIdTokenVerifier(project, async () => { const error = new Error(`timeout ${secretLike}`); error.name = "AbortError"; throw error; });
    await assert.rejects(verifier.verify(token()), ApiError);
    assert.match(JSON.stringify(logs), /timeout/);
    assert.equal(JSON.stringify(logs).includes(secretLike), false);
  } finally { console.error = original; }
});

test("default fetch wrappers preserve the native global receiver across certificate, OAuth, and Firestore calls", async () => {
  clearFirebaseCertCacheForTests();
  const originalFetch = globalThis.fetch; const calls: string[] = [];
  globalThis.fetch = (async function(this: typeof globalThis, input: RequestInfo | URL): Promise<Response> {
    assert.equal(this, globalThis);
    const url = String(input); calls.push(url);
    if (url.includes("securetoken@system.gserviceaccount.com")) return Response.json({ "test-key": pem }, { headers: { "cache-control": "max-age=3600" } });
    if (url === "https://oauth2.googleapis.com/token") return Response.json({ access_token: "mock-access", expires_in: 3600 });
    if (url.includes("firestore.googleapis.com")) return Response.json([]);
    throw new Error("unexpected mocked URL");
  }) as typeof fetch;
  try {
    assert.equal((await new FirebaseIdTokenVerifier(project).verify(token())).sub, "owner-1");
    const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    const auth = new GoogleAdminAuth({ FIREBASE_PROJECT_ID: project, GOOGLE_SERVICE_ACCOUNT_JSON: JSON.stringify({ client_email: "worker@example.test", private_key: privatePem }) });
    assert.equal(await auth.accessToken(), "mock-access");
    assert.deepEqual(await new FirestoreRestStore(project, auth).query("controllerUnpairOperations", {}), []);
    assert.equal(calls.length, 3);
  } finally { globalThis.fetch = originalFetch; clearFirebaseCertCacheForTests(); }
});

test("Google OAuth network and HTTP failures produce safe diagnostics", async () => {
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const env = { FIREBASE_PROJECT_ID: project, GOOGLE_SERVICE_ACCOUNT_JSON: JSON.stringify({ client_email: "worker@example.test", private_key: privatePem }) };
  const network = new GoogleAdminAuth(env, async () => { throw new TypeError("sensitive network details"); });
  await assert.rejects(network.accessToken(), ApiError);
  const rejected = new GoogleAdminAuth(env, async () => new Response("private oauth response", { status: 403 }));
  await assert.rejects(rejected.accessToken(), ApiError);
  const malformed = new GoogleAdminAuth(env, async () => new Response("not-json"));
  await assert.rejects(malformed.accessToken(), ApiError);
});

test("Google OAuth caches successful access tokens", async () => {
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" }).toString(); let requests = 0;
  const env = { FIREBASE_PROJECT_ID: project, GOOGLE_SERVICE_ACCOUNT_JSON: JSON.stringify({ client_email: "worker@example.test", private_key: privatePem }) };
  const auth = new GoogleAdminAuth(env, async (_input, init) => { requests++; const form = new URLSearchParams(String(init?.body)); assert.equal(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer"); return Response.json({ access_token: "mock-token", expires_in: 3600 }); });
  assert.equal(await auth.accessToken(), "mock-token"); assert.equal(await auth.accessToken(), "mock-token"); assert.equal(requests, 1);
});

test("Firestore preserves generic API errors while classifying HTTP authorization failures", async () => {
  const auth = { accessToken: async () => "mock-access" } as never;
  const store = new FirestoreRestStore(project, auth, async () => new Response("private upstream detail", { status: 403 }));
  await assert.rejects(store.query("controllerUnpairOperations", {}), (error: unknown) => error instanceof ApiError && error.code === "permission-denied" && error.message === "Firestore request failed.");
  const network = new FirestoreRestStore(project, auth, async () => { throw new TypeError("private network detail"); });
  await assert.rejects(network.query("controllerUnpairOperations", {}), (error: unknown) => error instanceof ApiError && error.message === "Firestore is temporarily unavailable.");
});

test("Firestore maps upstream status classes and rejects malformed JSON safely", async () => {
  const auth = { accessToken: async () => "mock-access" } as never;
  for (const [status, expected] of [[401, "internal"], [403, "permission-denied"], [404, "not-found"], [429, "internal"], [503, "unavailable"]] as const) {
    const store = new FirestoreRestStore(project, auth, async () => new Response("private body", { status }));
    await assert.rejects(store.query("controllerUnpairOperations", {}), (error: unknown) => error instanceof ApiError && error.code === expected);
  }
  const malformed = new FirestoreRestStore(project, auth, async () => new Response("not-json"));
  await assert.rejects(malformed.query("controllerUnpairOperations", {}), (error: unknown) => error instanceof ApiError && error.message === "Firestore is temporarily unavailable.");
});

test("Firestore 403 diagnostics extract safe Google error metadata and omit raw body details", async () => {
  const originalError = console.error; const logs: unknown[][] = []; console.error = (...args: unknown[]) => { logs.push(args); };
  const upstream = {
    error: {
      code: 403,
      status: "PERMISSION_DENIED",
      message: "Permission denied for user private-user-123 with token secret-access-token",
      details: [{
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        reason: "IAM_PERMISSION_DENIED",
        domain: "firestore.googleapis.com",
        metadata: { resource: "private-document-id", credential: "service-account-secret" },
      }],
    },
  };
  try {
    const store = new FirestoreRestStore(project, { accessToken: async () => "do-not-log-access-token" } as never,
      async () => Response.json(upstream, { status: 403 }));
    await assert.rejects(store.query("controllerUnpairOperations", {}), (error: unknown) => error instanceof ApiError && error.code === "permission-denied" && error.message === "Firestore request failed.");
    const logged = JSON.stringify(logs);
    assert.match(logged, /"status":403/);
    assert.match(logged, /"googleStatus":"PERMISSION_DENIED"/);
    assert.match(logged, /"messageCategory":"permission_denied"/);
    assert.match(logged, /"reason":"IAM_PERMISSION_DENIED"/);
    assert.match(logged, /"domain":"firestore.googleapis.com"/);
    for (const sensitive of [upstream.error.message, "private-user-123", "secret-access-token", "private-document-id", "service-account-secret", "do-not-log-access-token"]) {
      assert.equal(logged.includes(sensitive), false);
    }
  } finally { console.error = originalError; }
});

test("scheduled handler contains configuration and Firestore failures", async () => {
  await assert.doesNotReject(worker.scheduled({ scheduledTime: Date.now(), cron: "* * * * *" }, { FIREBASE_PROJECT_ID: project }));
});

test("sensitive structured log fields and token-like values are redacted", () => {
  const safe = redactFields({ token: "a".repeat(43), uid: "person@example.com", status: 200, detail: { password: "bad" } });
  assert.equal(safe.token, "[REDACTED]");
  assert.equal(safe.uid, "person@example.com");
  assert.equal(safe.status, 200);
  assert.equal(safe.detail, "[OMITTED]");
});

test("health endpoint is public and exposes only a boolean", async () => {
  const response = await worker.fetch(new Request("https://worker.test/health"), { FIREBASE_PROJECT_ID: project });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test("HTTP rejects malformed, oversized, wrong content type, and missing authentication", async () => {
  const env = { FIREBASE_PROJECT_ID: project, MAX_REQUEST_BYTES: "1024" };
  const wrongType = await worker.fetch(new Request("https://worker.test/v1/controller/pairing-sessions", { method: "POST", body: "{}" }), env);
  assert.equal(wrongType.status, 400);
  const malformed = await worker.fetch(new Request("https://worker.test/v1/controller/pairing-sessions", { method: "POST", headers: { "content-type": "application/json" }, body: "{" }), env);
  assert.equal(malformed.status, 400);
  const oversized = await worker.fetch(new Request("https://worker.test/v1/controller/pairing-sessions", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ data: "x".repeat(1200) }) }), env);
  assert.equal(oversized.status, 413);
  const unauthenticated = await worker.fetch(new Request("https://worker.test/v1/controller/pairing-sessions", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ houseId: "house" }) }), env);
  assert.equal(unauthenticated.status, 401);
});

class MemoryStore {
  docs = new Map<string, Record<string, unknown>>();
  doc(collection: string, id: string) { return { toString: () => `${collection}/${id}` }; }
  async runTransaction<T>(callback: (tx: { get(ref: object): Promise<{ exists: boolean; data(): Record<string, unknown> | undefined }>; create(ref: object, data: Record<string, unknown>): void; update(ref: object, data: Record<string, unknown>): void }) => Promise<T>): Promise<T> {
    const writes: Array<() => void> = [];
    const tx = {
      get: async (ref: object) => { const value = this.docs.get(String(ref)); return { exists: !!value, data: () => value ? { ...value } : undefined }; },
      create: (ref: object, data: Record<string, unknown>) => writes.push(() => { if (this.docs.has(String(ref))) throw new Error("exists"); this.docs.set(String(ref), { ...data }); }),
      update: (ref: object, data: Record<string, unknown>) => writes.push(() => this.docs.set(String(ref), { ...this.docs.get(String(ref)), ...data })),
    };
    const result = await callback(tx);
    for (const write of writes) write();
    return result;
  }
}

test("pairing session enforces approved Owner/House authorization and stores only token hash", async () => {
  const store = new MemoryStore();
  store.docs.set("users/owner-1", { id: "owner-1", role: "owner", houseId: "house-1", isApproved: true });
  store.docs.set("houses/house-1", { houseId: "house-1", ownerUid: "owner-1", mainControllerId: null });
  const tokenValue = "a".repeat(43);
  const result = await createPairingSession({ store, uid: "owner-1", houseId: "house-1", token: tokenValue, now: new Date(1000), serverTimestamp: new Date(1000) });
  assert.equal(result.expiresAt.getTime(), 301_000);
  const session = [...store.docs.entries()].find(([key]) => key.startsWith("pairingSessions/"));
  assert.ok(session);
  assert.equal(session[1].tokenHash, session[0].split("/")[1]);
  assert.equal(session[0].includes(tokenValue), false);
  store.docs.set("users/owner-2", { id: "owner-2", role: "owner", houseId: "house-1", isApproved: false });
  await assert.rejects(createPairingSession({ store, uid: "owner-2", houseId: "house-1", token: "b".repeat(43), now: new Date(1000), serverTimestamp: new Date(1000) }), (error: unknown) => error instanceof PairingError && error.code === "permission-denied");
});

test("pairing claim binds controller atomically, rejects replay, and supports bounded recovery", async () => {
  const store = new MemoryStore();
  const tokenValue = "t".repeat(43); const recovery = "r".repeat(43); const controllerId = "CTRL_001122aabbcc";
  const tokenHash = hashPairingToken(tokenValue);
  store.docs.set("pairingSessions/" + tokenHash, { tokenHash, houseId: "house-1", ownerUid: "owner-1", expiresAt: new Date(10_000), consumedAt: null });
  store.docs.set("users/owner-1", { id: "owner-1", role: "owner", houseId: "house-1", isApproved: true });
  store.docs.set("houses/house-1", { houseId: "house-1", ownerUid: "owner-1", mainControllerId: null });
  const claimed = await claimMainController({ store, token: tokenValue, controllerId, recoverySecret: recovery, now: new Date(1000), serverTimestamp: new Date(1000) });
  assert.deepEqual(claimed, { houseId: "house-1", controllerId });
  assert.equal(store.docs.get("houses/house-1")?.mainControllerId, controllerId);
  assert.deepEqual(await claimMainController({ store, token: tokenValue, controllerId, recoverySecret: recovery, now: new Date(1000), serverTimestamp: new Date(1000) }), { houseId: "house-1", controllerId });
  const recovered = await recoverMainControllerCredential({ store, recoverySecret: recovery, controllerId, now: new Date(2000) });
  assert.equal(recovered.credentialGeneration, 1);
  await assert.rejects(recoverMainControllerCredential({ store, recoverySecret: recovery, controllerId, now: new Date(700_000) }), PairingError);
});

test("Auth provisioning failure after assignment leaves a recoverable claim", async () => {
  const store = new MemoryStore(); const pairingToken = "f".repeat(43); const recovery = "g".repeat(43); const controllerId = "CTRL_001122aabbcc";
  const hash = hashPairingToken(pairingToken);
  store.docs.set(`pairingSessions/${hash}`, { tokenHash: hash, houseId: "house-1", ownerUid: "owner-1", expiresAt: new Date(50_000), consumedAt: null });
  store.docs.set("users/owner-1", { id: "owner-1", role: "owner", houseId: "house-1", isApproved: true });
  store.docs.set("houses/house-1", { houseId: "house-1", ownerUid: "owner-1", mainControllerId: null });
  const assignment = await claimMainController({ store, token: pairingToken, controllerId, recoverySecret: recovery, now: new Date(1000), serverTimestamp: new Date(1000) });
  await assert.rejects(Promise.reject(new Error("mock Auth Admin unavailable")), /Auth Admin unavailable/);
  assert.equal(store.docs.get("houses/house-1")?.mainControllerId, controllerId);
  assert.equal((await recoverMainControllerCredential({ store, recoverySecret: recovery, controllerId, now: new Date(2000) })).houseId, assignment.houseId);
});

test("concurrent claims cannot assign one pairing capability to two controllers", async () => {
  const store = new MemoryStore();
  const pairingToken = "p".repeat(43); const hash = hashPairingToken(pairingToken);
  store.docs.set(`pairingSessions/${hash}`, { tokenHash: hash, houseId: "house-1", ownerUid: "owner-1", expiresAt: new Date(30_000), consumedAt: null });
  store.docs.set("users/owner-1", { id: "owner-1", role: "owner", houseId: "house-1", isApproved: true });
  store.docs.set("houses/house-1", { houseId: "house-1", ownerUid: "owner-1", mainControllerId: null });
  const results = await Promise.allSettled(["CTRL_001122aabbcc", "CTRL_001122aabbdd"].map(controllerId => claimMainController({ store, token: pairingToken, controllerId, recoverySecret: "q".repeat(43), now: new Date(1000), serverTimestamp: new Date(1000) })));
  assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
});

test("unpair preserves prepare/commit ordering and duplicate acknowledgements", async () => {
  const store = new MemoryStore(); const id = "CTRL_001122aabbcc";
  store.docs.set("users/owner-1", { id: "owner-1", role: "owner", houseId: "house-1", isApproved: true });
  store.docs.set("houses/house-1", { houseId: "house-1", ownerUid: "owner-1", mainControllerId: id });
  store.docs.set(`controllers/${id}`, { controllerId: id, activeHouseId: "house-1", status: "paired" });
  const operationId = "o".repeat(32); const now = new Date(1000);
  await requestMainControllerUnpair({ store, uid: "owner-1", houseId: "house-1", controllerId: id, operationId, now, expiresAt: new Date(50_000), serverTimestamp: now });
  await assert.rejects(acknowledgeMainControllerUnpairCompleted({ store, operationId, controllerId: id, now, serverTimestamp: now }), PairingError);
  const prepared = await acknowledgeMainControllerUnpairPrepared({ store, operationId, controllerId: id, now, serverTimestamp: now });
  assert.equal(prepared.status, "prepared");
  assert.equal((await acknowledgeMainControllerUnpairPrepared({ store, operationId, controllerId: id, now, serverTimestamp: now })).status, "prepared");
  const completed = await acknowledgeMainControllerUnpairCompleted({ store, operationId, controllerId: id, now, serverTimestamp: now });
  assert.equal(completed.status, "completed");
  assert.equal(store.docs.get("houses/house-1")?.mainControllerId, null);
  assert.equal((await acknowledgeMainControllerUnpairCompleted({ store, operationId, controllerId: id, now, serverTimestamp: now })).status, "completed");
});

test("Cron expiry fails overdue pending operation while retaining safe registry semantics", async () => {
  const store = new MemoryStore(); const id = "CTRL_001122aabbcc"; const operationId = "e".repeat(32);
  store.docs.set(`controllerUnpairOperations/${operationId}`, { operationId, houseId: "house-1", controllerId: id, status: "pending", expiresAt: new Date(1000) });
  store.docs.set("houses/house-1", { houseId: "house-1", mainControllerId: id, pendingUnpairOperationId: operationId });
  store.docs.set(`controllers/${id}`, { controllerId: id, activeHouseId: "house-1", pendingUnpairOperationId: operationId, status: "unpair_pending" });
  assert.equal(await expireMainControllerUnpair({ store, operationId, now: new Date(2000), serverTimestamp: new Date(2000) }), true);
  assert.equal(store.docs.get(`controllerUnpairOperations/${operationId}`)?.status, "failed");
  assert.equal(store.docs.get("houses/house-1")?.mainControllerId, id);
  assert.equal(store.docs.get("houses/house-1")?.pendingUnpairOperationId, null);
});

test("device identity claims are bound to UID, controller, generation, state, expiry and revocation", () => {
  const args = { uid: "smartassist-controller-CTRL_001122aabbcc", controllerId: "CTRL_001122aabbcc", claims: { deviceType: "main-controller", controllerId: "CTRL_001122aabbcc", credentialGeneration: 2, exp: now + 60, auth_time: now }, expectedAuthUid: "smartassist-controller-CTRL_001122aabbcc", expectedGeneration: 2, credentialStatus: "active", operationStatus: "pending", operationControllerId: "CTRL_001122aabbcc", operationHouseId: "house-1", assignedHouseId: "house-1", nowSeconds: now, tokensValidAfterSeconds: now - 1 };
  assert.doesNotThrow(() => validateControllerIdentityClaims(args));
  assert.throws(() => validateControllerIdentityClaims({ ...args, claims: { ...args.claims, credentialGeneration: 1 } }), PairingError);
  assert.throws(() => validateControllerIdentityClaims({ ...args, tokensValidAfterSeconds: now + 1 }), PairingError);
});

test("privileged Auth checks reject disabled and revoked Firebase users", async () => {
  const google = { accessToken: async () => "mock-access" } as never;
  const env = { FIREBASE_PROJECT_ID: project, FIREBASE_WEB_API_KEY: "public-key" };
  const admin = new FirebaseAuthAdmin(env, google, async (_url, init) => {
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer mock-access");
    return new Response(JSON.stringify({ users: [{ localId: "uid", validSince: "100", disabled: false }] }), { status: 200 });
  });
  await admin.assertActiveToken("uid", 101);
  await assert.rejects(admin.assertActiveToken("uid", 99), ApiError);
  const disabled = new FirebaseAuthAdmin(env, google, async () => new Response(JSON.stringify({ users: [{ localId: "uid", validSince: "0", disabled: true }] }), { status: 200 }));
  await assert.rejects(disabled.assertActiveToken("uid", 101), ApiError);
});

test("Firebase Auth lookup failures log safe category, status and Firebase error code", async () => {
  const originalError = console.error; const originalWarn = console.warn; const logs: unknown[][] = [];
  console.error = (...args: unknown[]) => { logs.push(args); }; console.warn = (...args: unknown[]) => { logs.push(args); };
  try {
    const auth = { accessToken: async () => "mock-access" } as never;
    const rejected = new FirebaseAuthAdmin({ FIREBASE_PROJECT_ID: project }, auth, async () => new Response(JSON.stringify({ error: { code: 400, message: "API_KEY_INVALID", status: "INVALID_ARGUMENT" } }), { status: 400 }));
    await assert.rejects(rejected.getUser("user-1"), (error: unknown) => error instanceof ApiError && error.status === 500);
    const event = JSON.stringify(logs);
    assert.match(event, /firebase_auth_lookup_http_failed/);
    assert.match(event, /"status":400/);
    assert.match(event, /API_KEY_INVALID|INVALID_ARGUMENT/);
    assert.equal(event.includes("mock-access"), false);
    logs.length = 0;
    const malformed = new FirebaseAuthAdmin({ FIREBASE_PROJECT_ID: project }, auth, async () => new Response("sensitive response body"));
    await assert.rejects(malformed.getUser("user-1"), (error: unknown) => error instanceof ApiError && error.code === "unavailable");
    assert.match(JSON.stringify(logs), /invalid_json/);
    assert.equal(JSON.stringify(logs).includes("sensitive response body"), false);
    logs.length = 0;
    const oauthFailure = new FirebaseAuthAdmin({ FIREBASE_PROJECT_ID: project }, { accessToken: async () => { throw new ApiError("unavailable", "OAuth unavailable"); } } as never, async () => { throw new Error("fetch must not run"); });
    await assert.rejects(oauthFailure.getUser("user-1"), ApiError);
    assert.match(JSON.stringify(logs), /oauth_token_acquisition/);
  } finally { console.error = originalError; console.warn = originalWarn; }
});

test("unconfigured MQTT transport fails closed without publishing", async () => {
  await assert.rejects(new UnconfiguredMqttTransport().publish("topic", "payload", 1, false), ApiError);
});

test("MQTT delivery failure records retry metadata and never completes unpair", async () => {
  const store = new MemoryStore(); const operationId = "x".repeat(32); const nowTime = new Date(10_000);
  store.docs.set(`controllerUnpairOperations/${operationId}`, { operationId, status: "pending", deliveryAttempts: 0 });
  const logs: string[] = [];
  const sent = await deliverUnpairOperation({ store,
    operation: { operationId, status: "pending", deliveryAttempts: 0, houseId: "house-1", controllerId: "CTRL_001122aabbcc", expiresAt: new Date(100_000) },
    mqtt: new UnconfiguredMqttTransport(), logger: { info: () => {}, error: () => {}, warn: event => logs.push(event) }, now: nowTime });
  assert.equal(sent, false);
  const saved = store.docs.get(`controllerUnpairOperations/${operationId}`)!;
  assert.equal(saved.status, "pending");
  assert.equal(saved.deliveryAttempts, 1);
  assert.equal((saved.nextDeliveryAt as Date).getTime(), nowTime.getTime() + 15_000);
  assert.deepEqual(logs, ["mqtt_delivery_unavailable"]);
});

test("unpair delivery preserves existing topic and payload contract", async () => {
  let published = "";
  const operationId = "z".repeat(32); const store = new MemoryStore();
  store.docs.set(`controllerUnpairOperations/${operationId}`, { operationId, status: "prepared", deliveryAttempts: 0 });
  const ok = await deliverUnpairOperation({ store, operation: { operationId, status: "prepared", deliveryAttempts: 0, houseId: "house-1", controllerId: "CTRL_001122aabbcc", expiresAt: new Date(1000) },
    mqtt: { publish: async (topic, payload, qos, retain) => { published = JSON.stringify({ topic, payload: JSON.parse(payload), qos, retain }); } },
    logger: { info: () => {}, error: () => {}, warn: () => {} }, now: new Date(0) });
  assert.equal(ok, true);
  assert.deepEqual(JSON.parse(published), { topic: "smartassist/house-1/controllers/CTRL_001122aabbcc/control", payload: { v: 1, type: "unpair", phase: "commit", operationId, houseId: "house-1", controllerId: "CTRL_001122aabbcc", expiresAt: "1970-01-01T00:00:01.000Z" }, qos: 1, retain: false });
});

test("Firestore transaction conflict retries a bounded transaction", async () => {
  const calls = { begins: 0, reads: 0, commits: 0 };
  const auth = { accessToken: async () => "mock-access" } as never;
  const fetcher = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    if (url.endsWith(":beginTransaction")) { calls.begins++; return Response.json({ transaction: `tx-${calls.begins}` }); }
    if (url.includes("?transaction=")) { calls.reads++; return Response.json({ fields: { count: { integerValue: "4" } } }); }
    if (url.endsWith(":commit")) { calls.commits++; return new Response("{}", { status: calls.commits === 1 ? 409 : 200 }); }
    throw new Error(`Unexpected Firestore request ${init?.method ?? "GET"}`);
  };
  const store = new FirestoreRestStore(project, auth, fetcher);
  const result = await store.runTransaction(async tx => {
    const ref = store.doc("controllers", "CTRL_001122aabbcc");
    const snap = await tx.get(ref);
    tx.update(ref, { count: Number(snap.data()?.count) + 1 });
    return snap.data()?.count;
  });
  assert.equal(result, 4);
  assert.deepEqual(calls, { begins: 2, reads: 2, commits: 2 });
});
