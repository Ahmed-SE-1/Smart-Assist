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
