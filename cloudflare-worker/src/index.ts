import { randomBytes } from "node:crypto";
import {
  acknowledgeMainControllerUnpairCompleted, acknowledgeMainControllerUnpairPrepared,
  claimMainController, controllerFirebaseAuthUid, createPairingSession,
  expireMainControllerUnpair, nextControllerCredentialGeneration,
  recoverMainControllerCredential,
  requestMainControllerUnpair, validateControllerId, validateControllerIdentityClaims,
  validateMacDerivedControllerId, validateUnpairOperationId,
} from "../../functions/src/controller_pairing.ts";
import { ApiError, mapFirebaseCode } from "./errors.ts";
import { FirebaseAuthAdmin } from "./firebase-auth-admin.ts";
import { FirestoreRestStore } from "./firestore-rest.ts";
import { GoogleAdminAuth } from "./google-auth.ts";
import { FirebaseIdTokenVerifier } from "./firebase-id-token.ts";
import { createLogger } from "./logging.ts";
import { UnconfiguredMqttTransport } from "./mqtt-adapter.ts";
import { deliverUnpairOperation } from "./unpair-delivery.ts";
import type { Env, FirebaseIdClaims } from "./types.ts";

const logger = createLogger((level, entry) => console[level === "error" ? "error" : level === "warn" ? "warn" : "log"](JSON.stringify(entry)));
const MAX_BODY_DEFAULT = 16_384;
interface ScheduledEventLike { scheduledTime: number; cron: string; }

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const origin = request.headers.get("Origin");
    const cors = corsHeaders(origin, env.CORS_ALLOWED_ORIGINS);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    try {
      if (request.method === "GET" && new URL(request.url).pathname === "/health") return json({ ok: true }, 200, cors);
      const url = new URL(request.url);
      if (!url.pathname.startsWith("/v1/")) throw new ApiError("not-found", "Route was not found.");
      if (request.method !== "POST" && !(request.method === "GET" && url.pathname.startsWith("/v1/controller/unpair-operations/"))) {
        throw new ApiError("invalid-argument", "HTTP method is not supported.");
      }
      const maxBody = boundedInt(env.MAX_REQUEST_BYTES, MAX_BODY_DEFAULT, 1024, 65536);
      const input = request.method === "POST" ? await readBody(request, maxBody) : {};
      const google = new GoogleAdminAuth(env);
      const auth = new FirebaseAuthAdmin(env, google);
      const store = new FirestoreRestStore(env.FIREBASE_PROJECT_ID, google);
      const verifier = new FirebaseIdTokenVerifier(env.FIREBASE_PROJECT_ID);
      const path = url.pathname;
      const now = new Date();
      const serverTimestamp = now;

      if (path === "/v1/controller/pairing-sessions" && request.method === "POST") {
        const identity = await requireUser(request, verifier, auth);
        const houseId = requiredString(input.houseId, "houseId");
        const token = randomBytes(32).toString("base64url");
        const result = await createPairingSession({ store, uid: identity.sub, houseId, token, now, serverTimestamp });
        return json({ ...result, expiresAt: result.expiresAt.toISOString(), token }, 200, cors);
      }
      if (path === "/v1/controller/claims" && request.method === "POST") {
        const token = requiredString(input.token, "token");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const recoverySecret = requiredString(input.recoverySecret, "recoverySecret");
        const result = await claimMainController({ store, token, controllerId, recoverySecret, now, serverTimestamp });
        const deviceCredential = await provision(store, auth, result.houseId, controllerId);
        return json({ ...result, status: "paired", deviceCredential }, 200, cors);
      }
      if (path === "/v1/controller/credentials/recover" && request.method === "POST") {
        const recoverySecret = requiredString(input.recoverySecret, "recoverySecret");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const result = await recoverMainControllerCredential({ store, recoverySecret, controllerId, now });
        const deviceCredential = await provision(store, auth, result.houseId, controllerId, result.credentialGeneration);
        return json({ status: "paired", ...result, deviceCredential }, 200, cors);
      }
      if (path === "/v1/controller/unpair-operations" && request.method === "POST") {
        const identity = await requireUser(request, verifier, auth);
        const houseId = requiredString(input.houseId, "houseId");
        const controllerId = validateControllerId(input.controllerId);
        const operation = await requestMainControllerUnpair({ store, uid: identity.sub, houseId, controllerId,
          operationId: randomBytes(24).toString("base64url"), now,
          expiresAt: new Date(now.getTime() + 24 * 60 * 60 * 1000), serverTimestamp });
        await deliverUnpairOperation({ store, operation, mqtt: new UnconfiguredMqttTransport(), logger, now });
        return json(publicOperation(operation), 200, cors);
      }
      const match = path.match(/^\/v1\/controller\/unpair-operations\/([A-Za-z0-9_-]{32,64})(?:\/(retry|prepared|completed))?$/);
      if (match) {
        const operationId = validateUnpairOperationId(match[1]);
        const action = match[2];
        if (request.method === "GET" && !action) {
          const identity = await requireUser(request, verifier, auth);
          const operation = await store.get("controllerUnpairOperations", operationId);
          if (!operation) throw new ApiError("not-found", "Unpair operation was not found.");
          await assertOwner(store, identity.sub, String(operation.houseId ?? ""));
          return json(publicOperation(operation), 200, cors);
        }
        if (action === "retry" && request.method === "POST") {
          const identity = await requireUser(request, verifier, auth);
          const operation = await store.get("controllerUnpairOperations", operationId);
          if (!operation) throw new ApiError("not-found", "Unpair operation was not found.");
          await assertOwner(store, identity.sub, String(operation.houseId ?? ""));
          if (operation.status !== "pending" && operation.status !== "prepared") throw new ApiError("failed-precondition", "Unpair operation is not retryable.");
          await deliverUnpairOperation({ store, operation: { ...operation, operationId }, mqtt: new UnconfiguredMqttTransport(), logger, now });
          return json(publicOperation((await store.get("controllerUnpairOperations", operationId)) ?? operation), 200, cors);
        }
        if (action === "prepared" || action === "completed") {
          if (request.method !== "POST") throw new ApiError("invalid-argument", "HTTP method is not supported.");
          const controllerId = validateControllerId(input.controllerId);
          const claims = await requireDevice(request, verifier, auth, controllerId, operationId, store, now);
          void claims;
          const args = { store, operationId, controllerId, now, serverTimestamp };
          const result = action === "prepared"
            ? await acknowledgeMainControllerUnpairPrepared(args)
            : await acknowledgeMainControllerUnpairCompleted(args);
          if (action === "prepared") await deliverUnpairOperation({ store, operation: result as unknown as Record<string, unknown>, mqtt: new UnconfiguredMqttTransport(), logger, now });
          return json(publicOperation(result), 200, cors);
        }
      }
      throw new ApiError("not-found", "Route was not found.");
    } catch (error) {
      const mapped = normalizeError(error);
      logger.warn("request_failed", { code: mapped.code, status: mapped.status });
      return json({ error: { code: mapped.code, message: mapped.message } }, mapped.status, cors);
    }
  },

  async scheduled(_event: ScheduledEventLike, env: Env): Promise<void> {
    let stage = "initialization";
    try {
    logger.info("scheduled_unpair_sweep_started", { stage });
    const google = new GoogleAdminAuth(env);
    const store = new FirestoreRestStore(env.FIREBASE_PROJECT_ID, google);
    const mqtt = new UnconfiguredMqttTransport();
    const now = new Date();
    stage = "due_query";
    const due = await store.query("controllerUnpairOperations", { where: { compositeFilter: { op: "AND", filters: [
      { fieldFilter: { field: { fieldPath: "status" }, op: "IN", value: { arrayValue: { values: [{ stringValue: "pending" }, { stringValue: "prepared" }] } } } },
      { fieldFilter: { field: { fieldPath: "nextDeliveryAt" }, op: "LESS_THAN_OR_EQUAL", value: { timestampValue: now.toISOString() } } },
    ] } }, limit: 100 });
    stage = "due_processing";
    for (const row of due) {
      const op = row.data;
      const expiresAt = op.expiresAt instanceof Date ? op.expiresAt.getTime() : Number.NaN;
      const nextAt = op.nextDeliveryAt instanceof Date ? op.nextDeliveryAt.getTime() : 0;
      if (op.status === "pending" && expiresAt <= now.getTime()) {
        await expireMainControllerUnpair({ store, operationId: row.id, now, serverTimestamp: now });
      } else if (nextAt <= now.getTime()) await deliverUnpairOperation({ store, operation: { ...op, operationId: row.id }, mqtt, logger, now });
    }
    stage = "expired_query";
    const expired = await store.query("controllerUnpairOperations", { where: { compositeFilter: { op: "AND", filters: [
      { fieldFilter: { field: { fieldPath: "status" }, op: "EQUAL", value: { stringValue: "pending" } } },
      { fieldFilter: { field: { fieldPath: "expiresAt" }, op: "LESS_THAN_OR_EQUAL", value: { timestampValue: now.toISOString() } } },
    ] } }, limit: 100 });
    stage = "expiration_processing";
    for (const row of expired) if (row.data.expiresAt instanceof Date && row.data.expiresAt <= now) {
      await expireMainControllerUnpair({ store, operationId: row.id, now, serverTimestamp: now });
    }
    logger.info("scheduled_unpair_sweep_completed", { dueCount: due.length, expiredCount: expired.length });
    } catch (error) {
      logger.error("scheduled_unpair_sweep_failed", {
        stage,
        category: error instanceof ApiError ? `api_${error.code}` : error instanceof Error ? error.name : "unknown",
      });
    }
  },
};

async function requireUser(request: Request, verifier: FirebaseIdTokenVerifier, auth: FirebaseAuthAdmin): Promise<FirebaseIdClaims> {
  const claims = await requireToken(request, verifier);
  await auth.assertActiveToken(claims.sub, claims.auth_time);
  return claims;
}
async function requireToken(request: Request, verifier: FirebaseIdTokenVerifier): Promise<FirebaseIdClaims> {
  const value = request.headers.get("Authorization") ?? "";
  const match = value.match(/^Bearer (\S+)$/);
  if (!match) throw new ApiError("unauthenticated", "A Firebase ID token is required.");
  return verifier.verify(match[1]);
}
async function requireDevice(request: Request, verifier: FirebaseIdTokenVerifier, auth: FirebaseAuthAdmin, controllerId: string, operationId: string, store: FirestoreRestStore, now: Date): Promise<FirebaseIdClaims> {
  const claims = await requireToken(request, verifier);
  const controller = await store.get("controllers", controllerId);
  const operation = await store.get("controllerUnpairOperations", operationId);
  if (!controller || !operation) throw new ApiError("not-found", "Unpair operation was not found.");
  const account = await auth.getUser(controllerFirebaseAuthUid(controllerId));
  if (!account) throw new ApiError("permission-denied", "Controller credential is invalid.");
  validateControllerIdentityClaims({ uid: claims.sub, controllerId, claims, expectedAuthUid: account.uid,
    expectedGeneration: Number(controller.authCredentialGeneration), credentialStatus: controller.authCredentialStatus,
    operationStatus: operation.status, operationControllerId: operation.controllerId, operationHouseId: operation.houseId,
    assignedHouseId: controller.activeHouseId, nowSeconds: Math.floor(now.getTime() / 1000), tokensValidAfterSeconds: account.validSinceSeconds });
  if (operationId !== operation.operationId) throw new ApiError("permission-denied", "Controller credential is invalid.");
  return claims;
}
async function assertOwner(store: FirestoreRestStore, uid: string, houseId: string): Promise<void> {
  const user = await store.get("users", uid);
  const house = await store.get("houses", houseId);
  if (!user || user.id !== uid || user.role !== "owner" || user.houseId !== houseId || user.isApproved !== true || !house || house.houseId !== houseId || house.ownerUid !== uid) {
    throw new ApiError("permission-denied", "Approved House owner access is required.");
  }
}
async function provision(store: FirestoreRestStore, auth: FirebaseAuthAdmin, houseId: string, controllerId: string, expectedGeneration?: number) {
  const controller = await store.get("controllers", controllerId);
  if (!controller || controller.activeHouseId !== houseId || controller.controllerId !== controllerId || controller.pendingUnpairOperationId != null) throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
  const uid = controllerFirebaseAuthUid(controllerId);
  let account = await auth.getUser(uid);
  if (!account) account = await auth.createUser(uid);
  if (Object.keys(account.customClaims).length > 0 &&
    (account.customClaims.deviceType !== "main-controller" || account.customClaims.controllerId !== controllerId)) {
    throw new ApiError("already-exists", "Controller identity account has conflicting claims.");
  }
  const generation = nextControllerCredentialGeneration(controller.authCredentialGeneration, controller.authCredentialStatus);
  if (expectedGeneration != null && expectedGeneration !== generation) throw new ApiError("failed-precondition", "Controller credential generation changed during recovery.");
  await store.runTransaction(async tx => {
    const ref = store.doc("controllers", controllerId);
    const current = await tx.get(ref);
    const data = current.data();
    if (!current.exists || data?.activeHouseId !== houseId || data?.controllerId !== controllerId || data.pendingUnpairOperationId != null) throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
    tx.update(ref, { firebaseAuthUid: uid, authCredentialGeneration: generation, authCredentialStatus: "provisioning" });
  });
  const claims = { deviceType: "main-controller", controllerId, credentialGeneration: generation };
  await auth.updateUser(uid, { customClaims: claims, disabled: false,
    ...(controller.authCredentialStatus === "revoked" ? { revokeBeforeSeconds: Math.floor(Date.now() / 1000) } : {}) });
  const customToken = await auth.createCustomToken(uid, claims);
  await store.runTransaction(async tx => {
    const ref = store.doc("controllers", controllerId);
    const current = await tx.get(ref);
    if (!current.exists || current.data()?.activeHouseId !== houseId || current.data()?.controllerId !== controllerId) throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
    tx.update(ref, { firebaseAuthUid: uid, authCredentialGeneration: generation, authCredentialStatus: "active" });
  });
  return { customToken, authUid: uid, credentialGeneration: generation };
}
function publicOperation(operation: Record<string, unknown>): Record<string, unknown> {
  const result = { ...operation };
  for (const field of ["requestedBy", "deliveryAttempts", "nextDeliveryAt", "lastDeliveryAt", "failureCode"]) delete result[field];
  for (const [key, value] of Object.entries(result)) if (value instanceof Date) result[key] = value.toISOString();
  return result;
}
async function readBody(request: Request, maxBytes: number): Promise<Record<string, unknown>> {
  if (!request.headers.get("content-type")?.toLowerCase().includes("application/json")) throw new ApiError("invalid-argument", "Content-Type must be application/json.");
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > maxBytes) throw new ApiError("resource-exhausted", "Request body is too large.", 413);
  const text = await request.text();
  if (new TextEncoder().encode(text).length > maxBytes) throw new ApiError("resource-exhausted", "Request body is too large.", 413);
  try { const body = JSON.parse(text) as unknown; if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error(); return body as Record<string, unknown>; }
  catch { throw new ApiError("invalid-argument", "Request body must be a JSON object."); }
}
function requiredString(value: unknown, name: string): string { if (typeof value !== "string" || value.length === 0) throw new ApiError("invalid-argument", `${name} is required.`); return value; }
function boundedInt(value: string | undefined, fallback: number, min: number, max: number): number { const parsed = Number(value); return Number.isInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback; }
function corsHeaders(origin: string | null, allow?: string): HeadersInit {
  if (!origin || !allow || !allow.split(",").map(s => s.trim()).includes(origin)) return {};
  return { "access-control-allow-origin": origin, "access-control-allow-methods": "GET,POST,OPTIONS", "access-control-allow-headers": "Authorization,Content-Type", vary: "Origin" };
}
function json(value: unknown, status: number, headers: HeadersInit = {}): Response { return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers } }); }
function normalizeError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  if (error instanceof Error && error.name === "PairingError") {
    const code = mapFirebaseCode((error as Error & { code?: string }).code ?? "internal");
    return new ApiError(code, error.message);
  }
  logger.error("internal_error", { name: error instanceof Error ? error.name : "unknown" });
  return new ApiError("internal", "The request could not be completed.");
}
