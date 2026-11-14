import { randomBytes } from "node:crypto";
import {
  acknowledgeMainControllerUnpairCompleted, acknowledgeMainControllerUnpairPrepared,
  claimMainController, consumeControllerIdentityMigrationSession,
  controllerFirebaseAuthUid, createControllerIdentityMigrationSession, createPairingSession,
  expireMainControllerUnpair, nextControllerCredentialGeneration,
  pollMainControllerOperation,
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
import type { Env, FirebaseIdClaims } from "./types.ts";

export async function fetchAllRowsByStatus(
  store: Pick<FirestoreRestStore, "query">,
  projectId: string,
  status: string,
): Promise<Array<{ id: string; data: any }>> {
  const all: Array<{ id: string; data: any }> = [];
  let cursor: string | undefined;
  const limit = 100;
  while (true) {
    const structuredQuery: Record<string, unknown> = {
      where: { fieldFilter: { field: { fieldPath: "status" }, op: "EQUAL", value: { stringValue: status } } },
      orderBy: [{ field: { fieldPath: "__name__" }, direction: "ASCENDING" }],
      limit,
    };
    if (cursor) {
      structuredQuery.startAt = {
        values: [{ referenceValue: `projects/${projectId}/databases/(default)/documents/controllerUnpairOperations/${encodeURIComponent(cursor)}` }],
        before: false,
      };
    }
    const rows = await store.query("controllerUnpairOperations", structuredQuery);
    if (rows.length === 0) break;
    all.push(...rows);
    if (rows.length < limit) break;
    cursor = rows[rows.length - 1].id;
  }
  return all;
}

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
      if (path === "/v1/controller/identity-migration-sessions" && request.method === "POST") {
        const identity = await requireUser(request, verifier, auth);
        const houseId = requiredString(input.houseId, "houseId");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const token = randomBytes(32).toString("base64url");
        const result = await createControllerIdentityMigrationSession({
          store,
          uid: identity.sub,
          houseId,
          controllerId,
          token,
          now,
          serverTimestamp,
        });
        return json({ ...result, expiresAt: result.expiresAt.toISOString(), token }, 200, cors);
      }
      if (path === "/v1/controller/claims" && request.method === "POST") {
        const token = requiredString(input.token, "token");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const recoverySecret = requiredString(input.recoverySecret, "recoverySecret");
        const result = await claimMainController({ store, token, controllerId, recoverySecret, now, serverTimestamp });
        const deviceCredential = await provision(store, auth, result.houseId, controllerId);
        return json({ houseId: result.houseId, controllerId, status: "paired", deviceCredential }, 200, cors);
      }
      if (path === "/v1/controller/identity/migrate" && request.method === "POST") {
        const token = requiredString(input.token, "token");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const recoverySecret = requiredString(input.recoverySecret, "recoverySecret");
        const result = await consumeControllerIdentityMigrationSession({
          store,
          token,
          controllerId,
          recoverySecret,
          now,
          serverTimestamp,
        });
        const deviceCredential = await provision(store, auth, result.houseId, controllerId, result.credentialGeneration, true);
        return json({ houseId: result.houseId, controllerId, status: "paired", deviceCredential }, 200, cors);
      }
      if (path === "/v1/controller/credentials/recover" && request.method === "POST") {
        const recoverySecret = requiredString(input.recoverySecret, "recoverySecret");
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const result = await recoverMainControllerCredential({ store, recoverySecret, controllerId, now });
        const deviceCredential = await provision(
          store, auth, result.houseId, controllerId, result.credentialGeneration,
          result.rotateGeneration,
        );
        return json({ status: "paired", ...result, deviceCredential }, 200, cors);
      }
      if (path === "/v1/controller/readiness" && request.method === "POST") {
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const identity = await requireControllerIdentity(request, verifier, auth, store, controllerId, now);
        if (input.storageMode !== "encrypted_nvs") {
          throw new ApiError("failed-precondition", "Controller secure storage is not ready.");
        }
        const houseId = identity.houseId;
        await store.runTransaction(async tx => {
          const controllerRef = store.doc("controllers", controllerId);
          const houseRef = store.doc("houses", houseId);
          const controllerSnapshot = await tx.get(controllerRef);
          const houseSnapshot = await tx.get(houseRef);
          const controller = controllerSnapshot.data();
          const house = houseSnapshot.data();
          if (!controllerSnapshot.exists || !houseSnapshot.exists ||
            controller?.activeHouseId !== houseId || controller.controllerId !== controllerId ||
            controller.authCredentialGeneration !== identity.generation ||
            controller.authCredentialStatus !== "active" ||
            controller.pendingUnpairOperationId != null ||
            house?.mainControllerId !== controllerId || house.pendingUnpairOperationId != null) {
            throw new ApiError("failed-precondition", "Controller pairing changed before readiness confirmation.");
          }
          tx.update(controllerRef, {
            pairingReadiness: "cloud_ready",
            pairingGeneration: identity.generation,
            lastSeenAt: now,
            cloudReadyAt: now,
            identityMigrationTokenHash: null,
            identityMigrationExpiresAt: null,
          });
        });
        return json({ status: "cloud_ready", controllerId, houseId, credentialGeneration: identity.generation }, 200, cors);
      }
      if (path === "/v1/controller/operations/poll" && request.method === "POST") {
        const controllerId = validateMacDerivedControllerId(input.controllerId);
        const identity = await requireControllerIdentity(request, verifier, auth, store, controllerId, now);
        const operation = await pollMainControllerOperation({
          store,
          controllerId,
          credentialGeneration: identity.generation,
          now,
        });
        return json({ operation }, 200, cors);
      }
      if (path === "/v1/controller/unpair-operations" && request.method === "POST") {
        const identity = await requireUser(request, verifier, auth);
        const houseId = requiredString(input.houseId, "houseId");
        const controllerId = validateControllerId(input.controllerId);
        const operation = await requestMainControllerUnpair({ store, uid: identity.sub, houseId, controllerId,
          operationId: randomBytes(24).toString("base64url"), now,
          expiresAt: new Date(now.getTime() + 24 * 60 * 60 * 1000), serverTimestamp });
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
      const now = new Date();

      // HTTPS controller polling is the critical delivery channel. The scheduled
      // sweep only expires unprepared operations; prepared operations remain
      // durable and retryable until the controller polls and commits them.
      stage = "due_query";
      const pendingRows = await fetchAllRowsByStatus(store, env.FIREBASE_PROJECT_ID, "pending");

      // Sweep any remaining pending operations that have expired
      stage = "expired_processing";
      const expired = pendingRows.filter(row => {
        const op = row.data;
        return op.expiresAt instanceof Date && op.expiresAt.getTime() <= now.getTime();
      });
      for (const row of expired) {
        // Idempotently check / ensure expired
        await expireMainControllerUnpair({ store, operationId: row.id, now, serverTimestamp: now });
      }

      logger.info("scheduled_unpair_sweep_completed", { pendingCount: pendingRows.length, expiredCount: expired.length });
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
async function requireControllerIdentity(
  request: Request,
  verifier: FirebaseIdTokenVerifier,
  auth: FirebaseAuthAdmin,
  store: FirestoreRestStore,
  controllerId: string,
  now: Date,
): Promise<{ generation: number; houseId: string }> {
  const claims = await requireToken(request, verifier);
  const expectedUid = controllerFirebaseAuthUid(controllerId);
  const [controller, account] = await Promise.all([
    store.get("controllers", controllerId),
    auth.getUser(expectedUid),
  ]);
  const generation = Number(controller?.authCredentialGeneration);
  const houseId = typeof controller?.activeHouseId === "string" ? controller.activeHouseId : "";
  if (!controller || !account || account.disabled || claims.sub !== expectedUid ||
    !Number.isInteger(generation) || generation <= 0 ||
    controller.controllerId !== controllerId || controller.authCredentialStatus !== "active" ||
    !houseId || claims.deviceType !== "main-controller" ||
    claims.controllerId !== controllerId || claims.credentialGeneration !== generation ||
    account.customClaims.deviceType !== "main-controller" ||
    account.customClaims.controllerId !== controllerId ||
    account.customClaims.credentialGeneration !== generation ||
    typeof claims.auth_time !== "number" || claims.auth_time < account.validSinceSeconds ||
    typeof claims.exp !== "number" || claims.exp <= Math.floor(now.getTime() / 1000)) {
    throw new ApiError("permission-denied", "Controller identity is invalid or revoked.");
  }
  return { generation, houseId };
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
  const [user, house] = await Promise.all([
    store.get("users", uid),
    store.get("houses", houseId),
  ]);
  if (!user || user.id !== uid || user.role !== "owner" || user.houseId !== houseId || user.isApproved !== true || !house || house.houseId !== houseId || house.ownerUid !== uid) {
    throw new ApiError("permission-denied", "Approved House owner access is required.");
  }
}
async function provision(store: FirestoreRestStore, auth: FirebaseAuthAdmin, houseId: string, controllerId: string, expectedGeneration?: number, rotateGeneration = false) {
  const uid = controllerFirebaseAuthUid(controllerId);
  const [controller, existingAccount] = await Promise.all([
    store.get("controllers", controllerId),
    auth.getUser(uid),
  ]);
  if (!controller || controller.activeHouseId !== houseId || controller.controllerId !== controllerId || controller.pendingUnpairOperationId != null) throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
  let account = existingAccount;
  if (!account) account = await auth.createUser(uid);
  if (Object.keys(account.customClaims).length > 0 &&
    (account.customClaims.deviceType !== "main-controller" || account.customClaims.controllerId !== controllerId)) {
    throw new ApiError("already-exists", "Controller identity account has conflicting claims.");
  }
  const currentGeneration = Number.isInteger(controller.authCredentialGeneration)
    ? Number(controller.authCredentialGeneration) : 0;
  const generation = rotateGeneration && expectedGeneration != null
    ? expectedGeneration
    : nextControllerCredentialGeneration(controller.authCredentialGeneration, controller.authCredentialStatus);
  if (rotateGeneration && expectedGeneration != null) {
    const canStartRotation = generation === currentGeneration + 1;
    const canResumeRotation = generation === currentGeneration &&
      (controller.authCredentialStatus === "provisioning" || controller.authCredentialStatus === "active") &&
      controller.pairingReadiness !== "cloud_ready";
    if (!canStartRotation && !canResumeRotation) throw new ApiError("failed-precondition", "Controller identity changed during migration.");
  }
  if (expectedGeneration != null && expectedGeneration !== generation) throw new ApiError("failed-precondition", "Controller credential generation changed during recovery.");
  await store.runTransaction(async tx => {
    const ref = store.doc("controllers", controllerId);
    const current = await tx.get(ref);
    const data = current.data();
    if (!current.exists || data?.activeHouseId !== houseId || data?.controllerId !== controllerId || data.pendingUnpairOperationId != null) throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
    if (rotateGeneration) {
      const currentGeneration = Number.isInteger(data.authCredentialGeneration) ? Number(data.authCredentialGeneration) : 0;
      const canStartRotation = currentGeneration + 1 === generation;
      const canResumeRotation = currentGeneration === generation &&
        (data.authCredentialStatus === "provisioning" || data.authCredentialStatus === "active") &&
        data.pairingReadiness !== "cloud_ready";
      if (!canStartRotation && !canResumeRotation) throw new ApiError("failed-precondition", "Controller identity changed during migration.");
    }
    tx.update(ref, {
      firebaseAuthUid: uid,
      authCredentialGeneration: generation,
      authCredentialStatus: "provisioning",
      pairingReadiness: "pending",
    });
  });
  const claims = { deviceType: "main-controller", controllerId, credentialGeneration: generation };
  await auth.updateUser(uid, { customClaims: claims, disabled: false,
    ...(rotateGeneration || controller.authCredentialStatus === "revoked" ? { revokeBeforeSeconds: Math.floor(Date.now() / 1000) } : {}) });
  const customToken = await auth.createCustomToken(uid, claims);
  await store.runTransaction(async tx => {
    const ref = store.doc("controllers", controllerId);
    const current = await tx.get(ref);
    if (!current.exists || current.data()?.activeHouseId !== houseId ||
      current.data()?.controllerId !== controllerId ||
      current.data()?.authCredentialGeneration !== generation ||
      current.data()?.authCredentialStatus !== "provisioning" ||
      current.data()?.pendingUnpairOperationId != null) {
      throw new ApiError("failed-precondition", "Controller assignment changed during provisioning.");
    }
    tx.update(ref, {
      firebaseAuthUid: uid,
      authCredentialGeneration: generation,
      authCredentialStatus: "active",
      pairingReadiness: "pending",
    });
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
