import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import {
  FieldValue,
  getFirestore,
  Timestamp,
  type DocumentData,
  type DocumentReference,
} from "firebase-admin/firestore";
import { randomBytes, randomInt } from "node:crypto";
import mqtt from "mqtt";
import {
  HttpsError,
  onCall,
  type CallableRequest,
} from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";

import { requireAuthenticated, requireHouseMigrationAdmin } from "./auth.js";
import {
  PairingError,
  acknowledgeMainControllerUnpairCompleted as acknowledgeMainControllerUnpairCompletedOperation,
  acknowledgeMainControllerUnpairPrepared as acknowledgeMainControllerUnpairPreparedOperation,
  claimMainController as claimMainControllerOperation,
  recoverMainControllerCredential as recoverMainControllerCredentialOperation,
  consumeControllerIdentityMigrationSession,
  controllerFirebaseAuthUid,
  createPairingSession,
  createControllerIdentityMigrationSession as createControllerIdentityMigrationSessionOperation,
  expireMainControllerUnpair,
  nextControllerCredentialGeneration,
  type PairingStore,
  type PairingTransaction,
  recordUnpairDeliveryAttempt,
  requestMainControllerUnpair as requestMainControllerUnpairOperation,
  validateUnpairOperationId,
  validateControllerId,
  validateMacDerivedControllerId,
  validateControllerIdentityClaims,
  validatePairingToken,
  validateControllerRecoverySecret,
} from "./controller_pairing.js";
import {
  assertProfileDoesNotExist,
  buildHouseRegistryEntry,
  buildMemberProfile,
  buildOwnerProfile,
  houseNameIndexKey,
  houseRegistryConflict,
  normalizeHouseName,
  RegistrationDomainError,
} from "./registration_domain.js";

initializeApp();

const MAIN_CONTROLLER_MQTT_HOST = defineSecret("MAIN_CONTROLLER_MQTT_HOST");
const MAIN_CONTROLLER_MQTT_PORT = defineSecret("MAIN_CONTROLLER_MQTT_PORT");
const MAIN_CONTROLLER_MQTT_USERNAME = defineSecret("MAIN_CONTROLLER_MQTT_USERNAME");
const MAIN_CONTROLLER_MQTT_PASSWORD = defineSecret("MAIN_CONTROLLER_MQTT_PASSWORD");
const MAIN_CONTROLLER_MQTT_CA_CERT = defineSecret("MAIN_CONTROLLER_MQTT_CA_CERT");
const mainControllerMqttSecrets = [
  MAIN_CONTROLLER_MQTT_HOST,
  MAIN_CONTROLLER_MQTT_PORT,
  MAIN_CONTROLLER_MQTT_USERNAME,
  MAIN_CONTROLLER_MQTT_PASSWORD,
  MAIN_CONTROLLER_MQTT_CA_CERT,
];

/// Authenticated deployment probe. It returns no project secrets or user data.
export const healthCheck = onCall((request) => {
  let uid: string;
  try {
    uid = requireAuthenticated(request);
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    throw new HttpsError("internal", "Health check failed.");
  }
  return { ok: true, authenticated: true, uid };
});

function safeRegistrationError(error: unknown): never {
  if (error instanceof HttpsError) throw error;
  if (error instanceof RegistrationDomainError) {
    if (error.reason === "duplicate-profile") {
      throw new HttpsError("already-exists", "This account is already registered. Please sign in.");
    }
    if (error.reason === "invalid-house-name") {
      throw new HttpsError("invalid-argument", "Enter a valid House name.");
    }
    throw new HttpsError(
      "invalid-argument",
      "Registration could not be completed. Check the join code and try again.",
    );
  }
  throw new HttpsError("internal", "Registration could not be completed. Please try again.");
}

function safePairingError(error: unknown): never {
  if (error instanceof HttpsError) throw error;
  if (error instanceof PairingError) throw new HttpsError(error.code, error.message);
  throw new HttpsError("internal", "Controller operation could not be completed. Please try again.");
}

function pairingStore(): PairingStore {
  const db = getFirestore();
  return {
    doc: (collection, id) => db.collection(collection).doc(id),
    runTransaction: <T>(
      operation: (transaction: PairingTransaction) => Promise<T>,
    ): Promise<T> => db.runTransaction<T>(async (transaction) => {
      const adapter: PairingTransaction = {
        get: (ref) => transaction.get(ref as DocumentReference) as Promise<{
          exists: boolean;
          data(): Record<string, unknown> | undefined;
        }>,
        create: (ref, data) => transaction.create(ref as DocumentReference, data as DocumentData),
        update: (ref, data) => transaction.update(ref as DocumentReference, data as DocumentData),
      };
      return operation(adapter);
    }),
  };
}

function callableInput(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "Request data must be an object.");
  }
  return value as Record<string, unknown>;
}

/** Creates a five-minute, single-use pairing token for the signed-in House owner. */
export const createControllerPairingSession = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  try {
    const input = callableInput(request.data);
    const houseId = input.houseId;
    const token = randomBytes(32).toString("base64url");
    const now = new Date();
    const result = await createPairingSession({
      store: pairingStore(),
      uid,
      houseId: typeof houseId === "string" ? houseId : "",
      token,
      now,
      serverTimestamp: FieldValue.serverTimestamp(),
    });
    // Raw token is returned only to this authenticated owner; never log it.
    return { ...result, expiresAt: result.expiresAt.toISOString(), token };
  } catch (error) {
    safePairingError(error);
  }
});

/** Owner mints a five-minute migration token for an already paired legacy device. */
export const createControllerIdentityMigrationSession = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  try {
    const input = callableInput(request.data);
    const token = randomBytes(32).toString("base64url");
    const now = new Date();
    const result = await createControllerIdentityMigrationSessionOperation({
      store: pairingStore(),
      uid,
      houseId: typeof input.houseId === "string" ? input.houseId : "",
      controllerId: validateControllerId(input.controllerId),
      token,
      now,
      serverTimestamp: FieldValue.serverTimestamp(),
    });
    return { ...result, expiresAt: result.expiresAt.toISOString(), token };
  } catch (error) {
    safePairingError(error);
  }
});

/**
 * Device-only migration exchange. The five-minute single-use token is the
 * bootstrap credential; House assignment comes exclusively from its session.
 */
export const provisionExistingMainControllerIdentity = onCall(async (request) => {
  try {
    const input = callableInput(request.data);
    const token = validatePairingToken(input.token);
    const controllerId = validateControllerId(input.controllerId);
    const result = await consumeControllerIdentityMigrationSession({
      store: pairingStore(),
      token,
      controllerId,
      now: new Date(),
      serverTimestamp: FieldValue.serverTimestamp(),
    });
    const deviceCredential = await provisionControllerIdentity(result);
    return { status: "provisioned", controllerId, deviceCredential };
  } catch (error) {
    safePairingError(error);
  }
});

/**
 * Claims the controller using only a valid short-lived token. No House ID is
 * accepted from the device; the House is loaded from the hashed-token session.
 */
export const claimMainController = onCall(async (request) => {
  try {
    const input = callableInput(request.data);
    const token = validatePairingToken(input.token);
    const controllerId = validateMacDerivedControllerId(input.controllerId);
    const recoverySecret = validateControllerRecoverySecret(input.recoverySecret);
    const result = await claimMainControllerOperation({
      store: pairingStore(),
      token,
      controllerId,
      recoverySecret,
      now: new Date(),
      serverTimestamp: FieldValue.serverTimestamp(),
    });
    const deviceCredential = await provisionControllerIdentity({
      houseId: result.houseId,
      controllerId,
    });
    return { ...result, status: "paired", deviceCredential };
  } catch (error) {
    safePairingError(error);
  }
});

/** Device-only credential recovery using a short-lived capability bound at claim time. */
export const recoverMainControllerCredentials = onCall(async (request) => {
  try {
    const input = callableInput(request.data);
    const recoverySecret = validateControllerRecoverySecret(input.recoverySecret);
    const controllerId = validateMacDerivedControllerId(input.controllerId);
    const result = await recoverMainControllerCredentialOperation({
      store: pairingStore(),
      recoverySecret,
      controllerId,
      now: new Date(),
    });
    const deviceCredential = await provisionControllerIdentity({
      houseId: result.houseId,
      controllerId,
      expectedGeneration: result.credentialGeneration,
    });
    return { status: "paired", ...result, deviceCredential };
  } catch (error) {
    safePairingError(error);
  }
});

/**
 * Bind the device's Firebase Auth identity to a registry entry. Only an Admin
 * minted custom token can create this identity; credentials are never stored
 * in Firestore or logged.
 */
async function provisionControllerIdentity(args: {
  houseId: string;
  controllerId: string;
  expectedGeneration?: number;
}): Promise<{ customToken: string; authUid: string; credentialGeneration: number }> {
  const db = getFirestore();
  const auth = getAuth();
  const uid = controllerFirebaseAuthUid(args.controllerId);
  const ref = db.collection("controllers").doc(args.controllerId);
  let user;
  try {
    user = await auth.getUser(uid);
  } catch (error) {
    if ((error as { code?: string })?.code !== "auth/user-not-found") throw error;
    try {
      user = await auth.createUser({ uid, disabled: false });
    } catch (createError) {
      // Concurrent idempotent claim retries may race on the deterministic UID.
      if ((createError as { code?: string })?.code !== "auth/uid-already-exists") throw createError;
      user = await auth.getUser(uid);
    }
  }

  const snapshot = await ref.get();
  const controller = snapshot.data();
  if (!snapshot.exists || controller?.activeHouseId !== args.houseId ||
    controller?.controllerId !== args.controllerId || controller.pendingUnpairOperationId != null) {
    throw new HttpsError("failed-precondition", "Controller assignment changed during provisioning.");
  }
  if (controller.firebaseAuthUid != null && controller.firebaseAuthUid !== uid) {
    throw new HttpsError("already-exists", "Controller identity is already bound to another account.");
  }
  const priorStatus = controller.authCredentialStatus;
  const generation = nextControllerCredentialGeneration(
    controller.authCredentialGeneration,
    priorStatus,
  );
  if (args.expectedGeneration != null && generation !== args.expectedGeneration) {
    throw new HttpsError("failed-precondition", "Controller credential generation changed during recovery.");
  }
  const existingClaims = user.customClaims ?? {};
  if (Object.keys(existingClaims).length > 0 &&
    (existingClaims.deviceType !== "main-controller" ||
      existingClaims.controllerId !== args.controllerId)) {
    throw new HttpsError("already-exists", "Controller identity account has conflicting claims.");
  }

  // Mark provisioning first. Retrying the same claim keeps its generation;
  // a revoked identity gets a new generation and invalidates old ID tokens.
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const data = current.data();
    if (!current.exists || data?.activeHouseId !== args.houseId ||
      data?.controllerId !== args.controllerId || data.pendingUnpairOperationId != null) {
      throw new HttpsError("failed-precondition", "Controller assignment changed during provisioning.");
    }
    transaction.update(ref, {
      firebaseAuthUid: uid,
      authCredentialGeneration: generation,
      authCredentialStatus: "provisioning",
      authCredentialIssuedAt: FieldValue.serverTimestamp(),
    });
  });

  // A refresh token from the prior pairing must not acquire the new generation
  // when custom claims are updated. Revoke once for this generation; the marker
  // makes a retry after a partial Auth operation safe and repeatable.
  if (controller.authCredentialRefreshRevokedGeneration !== generation) {
    await auth.revokeRefreshTokens(uid);
    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(ref);
      const data = current.data();
      if (!current.exists || data?.activeHouseId !== args.houseId ||
        data?.authCredentialGeneration !== generation || data.pendingUnpairOperationId != null) {
        throw new HttpsError("failed-precondition", "Controller assignment changed during provisioning.");
      }
      transaction.update(ref, { authCredentialRefreshRevokedGeneration: generation });
    });
  }

  await auth.updateUser(uid, { disabled: false });
  await auth.setCustomUserClaims(uid, {
    deviceType: "main-controller",
    controllerId: args.controllerId,
    credentialGeneration: generation,
  });
  const customToken = await auth.createCustomToken(uid, {
    deviceType: "main-controller",
    controllerId: args.controllerId,
    credentialGeneration: generation,
  });
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const data = current.data();
    if (!current.exists || data?.activeHouseId !== args.houseId ||
      data?.authCredentialGeneration !== generation || data.pendingUnpairOperationId != null) {
      throw new HttpsError("failed-precondition", "Controller assignment changed during provisioning.");
    }
    transaction.update(ref, {
      authCredentialStatus: "active",
      authCredentialIssuedAt: FieldValue.serverTimestamp(),
      authCredentialRevokedAt: null,
    });
  });
  return { customToken, authUid: uid, credentialGeneration: generation };
}

async function requireControllerIdentity(
  request: CallableRequest<unknown>,
  controllerId: string,
  operationId: string,
  phase: "prepared" | "completed",
): Promise<{ uid: string; generation: number }> {
  const authContext = request.auth;
  if (!authContext) throw new HttpsError("unauthenticated", "Controller authentication is required.");
  const db = getFirestore();
  const [controllerSnapshot, operationSnapshot] = await Promise.all([
    db.collection("controllers").doc(controllerId).get(),
    db.collection("controllerUnpairOperations").doc(operationId).get(),
  ]);
  const controller = controllerSnapshot.data();
  const operation = operationSnapshot.data();
  const completedReplay = phase === "completed" && operation?.status === "completed";
  if (!controller || !operation || operation.controllerId !== controllerId ||
    typeof operation.houseId !== "string" ||
    (!completedReplay && controller.activeHouseId !== operation.houseId) ||
    (completedReplay && controller.activeHouseId != null) ||
    controller.firebaseAuthUid !== authContext.uid) {
    throw new HttpsError("permission-denied", "Controller is not authorized for this operation.");
  }
  const generation = controller.authCredentialGeneration;
  if (!Number.isInteger(generation)) {
    throw new HttpsError("permission-denied", "Controller credential is invalid or revoked.");
  }
  const user = await getAuth().getUser(authContext.uid);
  try {
    validateControllerIdentityClaims({
      uid: authContext.uid,
      controllerId,
      claims: authContext.token as Record<string, unknown>,
      expectedAuthUid: controllerFirebaseAuthUid(controllerId),
      expectedGeneration: generation as number,
      credentialStatus: controller.authCredentialStatus,
      operationStatus: operation.status,
      operationControllerId: operation.controllerId,
      operationHouseId: operation.houseId,
      assignedHouseId: controller.activeHouseId,
      nowSeconds: Math.floor(Date.now() / 1000),
      tokensValidAfterSeconds: Math.floor(new Date(user.tokensValidAfterTime ?? 0).getTime() / 1000),
    });
  } catch {
    throw new HttpsError("permission-denied", "Controller credential is invalid or revoked.");
  }
  if (phase === "prepared" && operation.status !== "pending" && operation.status !== "prepared") {
    throw new HttpsError("failed-precondition", "Unpair operation is not active.");
  }
  return { uid: authContext.uid, generation: generation as number };
}

function publicUnpairOperation(data: Record<string, unknown>): Record<string, unknown> {
  const dateValue = (value: unknown): string | null => {
    if (value instanceof Date) return value.toISOString();
    if (typeof value === "object" && value !== null && "toDate" in value &&
      typeof value.toDate === "function") {
      return (value.toDate() as Date).toISOString();
    }
    return null;
  };
  return {
    operationId: data.operationId,
    houseId: data.houseId,
    controllerId: data.controllerId,
    status: data.status,
    expiresAt: dateValue(data.expiresAt),
    createdAt: dateValue(data.createdAt),
    updatedAt: dateValue(data.updatedAt),
    deliveryAttempts: data.deliveryAttempts ?? 0,
  };
}

async function requireUnpairOperationOwner(
  uid: string,
  operation: Record<string, unknown> | undefined,
): Promise<void> {
  if (!operation || operation.requestedBy !== uid || typeof operation.houseId !== "string") {
    throw new HttpsError("not-found", "Unpair operation was not found.");
  }
  const db = getFirestore();
  const [userSnapshot, houseSnapshot] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.collection("houses").doc(operation.houseId).get(),
  ]);
  const user = userSnapshot.data();
  const house = houseSnapshot.data();
  if (
    user?.id !== uid || user.role !== "owner" || user.isApproved !== true ||
    user.houseId !== operation.houseId || house?.ownerUid !== uid ||
    house.houseId !== operation.houseId
  ) {
    throw new HttpsError("permission-denied", "Approved House owner access is required.");
  }
}

async function publishUnpairOperation(operationId: string): Promise<void> {
  const operationRef = getFirestore().collection("controllerUnpairOperations").doc(operationId);
  const snapshot = await operationRef.get();
  const operation = snapshot.data();
  if (!snapshot.exists || !operation ||
    (operation.status !== "pending" && operation.status !== "prepared")) return;

  const now = new Date();
  const attempts = Number(operation.deliveryAttempts ?? 0);
  const delayMs = Math.min(5 * 60_000, 15_000 * (2 ** Math.min(attempts, 4)));
  const status = await recordUnpairDeliveryAttempt({
    store: pairingStore(),
    operationId,
    nextDeliveryAt: new Date(now.getTime() + delayMs),
    serverTimestamp: FieldValue.serverTimestamp(),
  });
  if (!status) return;

  const host = MAIN_CONTROLLER_MQTT_HOST.value().trim();
  const port = Number(MAIN_CONTROLLER_MQTT_PORT.value());
  const username = MAIN_CONTROLLER_MQTT_USERNAME.value();
  const password = MAIN_CONTROLLER_MQTT_PASSWORD.value();
  const ca = MAIN_CONTROLLER_MQTT_CA_CERT.value();
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535 ||
    !username || !password || !ca) {
    throw new Error("Main Controller MQTT secrets are not configured.");
  }

  const client = mqtt.connect(`mqtts://${host}:${port}`, {
    username,
    password,
    clientId: `smartassist-functions-${randomBytes(8).toString("hex")}`,
    clean: true,
    connectTimeout: 10_000,
    reconnectPeriod: 0,
    rejectUnauthorized: true,
    ca,
  });
  try {
    await new Promise<void>((resolve, reject) => {
      client.once("connect", () => resolve());
      client.once("error", reject);
    });
    const phase = status === "pending" ? "prepare" : "commit";
    const topic = `smartassist/${operation.houseId}/controllers/${operation.controllerId}/control`;
    const payload = JSON.stringify({
      v: 1,
      type: "unpair",
      phase,
      operationId,
      houseId: operation.houseId,
      controllerId: operation.controllerId,
      expiresAt: operation.expiresAt instanceof Date
        ? operation.expiresAt.toISOString()
        : operation.expiresAt?.toDate?.().toISOString?.() ?? null,
    });
    await new Promise<void>((resolve, reject) => {
      client.publish(topic, payload, { qos: 1, retain: false }, (error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  } finally {
    client.end(true);
  }
}

async function requestUnpairHandler(request: CallableRequest<unknown>) {
  const uid = requireAuthenticated(request);
  try {
    const input = callableInput(request.data);
    const now = new Date();
    const operation = await requestMainControllerUnpairOperation({
      store: pairingStore(),
      uid,
      houseId: typeof input.houseId === "string" ? input.houseId : "",
      controllerId: validateControllerId(input.controllerId),
      operationId: randomBytes(24).toString("base64url"),
      now,
      expiresAt: new Date(now.getTime() + 24 * 60 * 60_000),
      serverTimestamp: FieldValue.serverTimestamp(),
    });
    const operationRef = getFirestore()
      .collection("controllerUnpairOperations")
      .doc(operation.operationId);
    if (operation.status === "pending") {
      try {
        await publishUnpairOperation(operation.operationId);
      } catch (error) {
        // The durable pending operation and scheduled retry are authoritative.
        logger.warn("Main Controller unpair delivery attempt failed", {
          operationId: operation.operationId,
          code: error instanceof Error ? error.name : "unknown",
        });
      }
    }
    const current = await operationRef.get();
    return publicUnpairOperation(current.data() ?? operation);
  } catch (error) {
    safePairingError(error);
  }
}

/** Starts or idempotently returns the owner’s durable unpair operation. */
export const requestMainControllerUnpair = onCall(
  { secrets: mainControllerMqttSecrets },
  requestUnpairHandler,
);

/** Compatibility callable: now starts an async operation, never clears directly. */
export const unpairMainController = onCall(
  { secrets: mainControllerMqttSecrets },
  requestUnpairHandler,
);

async function acknowledgeUnpairHandler(
  request: CallableRequest<unknown>,
  phase: "prepared" | "completed",
) {
  try {
    const input = callableInput(request.data);
    const operationId = validateUnpairOperationId(input.operationId);
    const controllerId = validateControllerId(input.controllerId);
    await requireControllerIdentity(request, controllerId, operationId, phase);
    const args = {
      store: pairingStore(),
      operationId,
      controllerId,
      now: new Date(),
      serverTimestamp: FieldValue.serverTimestamp(),
    };
    const operation = phase === "prepared"
      ? await acknowledgeMainControllerUnpairPreparedOperation(args)
      : await acknowledgeMainControllerUnpairCompletedOperation(args);
    // Keep the Firebase identity enabled for retrying this exact completed
    // acknowledgement. Registry status and generation checks deny all other
    // device operations; refresh tokens are revoked on the next pairing.
    if (phase === "prepared") {
      try {
        await publishUnpairOperation(operationId);
      } catch (error) {
        logger.warn("Main Controller unpair commit delivery failed", {
          operationId,
          code: error instanceof Error ? error.name : "unknown",
        });
      }
    }
    return publicUnpairOperation(operation as unknown as Record<string, unknown>);
  } catch (error) {
    safePairingError(error);
  }
}

/** Device-authenticated acknowledgement; requires Admin-issued Firebase custom claims. */
export const acknowledgeMainControllerUnpairPrepared = onCall(
  { secrets: mainControllerMqttSecrets },
  (request) => acknowledgeUnpairHandler(request, "prepared"),
);

/** Device-authenticated completion; only this operation clears both registry links. */
export const acknowledgeMainControllerUnpairCompleted = onCall(
  (request) => acknowledgeUnpairHandler(request, "completed"),
);

/** Owner-only durable status lookup, used by Flutter reconciliation. */
export const getMainControllerUnpairOperation = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  const input = callableInput(request.data);
  const operationId = validateUnpairOperationId(input.operationId);
  const snapshot = await getFirestore().collection("controllerUnpairOperations").doc(operationId).get();
  const operation = snapshot.data();
  if (!snapshot.exists || !operation) throw new HttpsError("not-found", "Unpair operation was not found.");
  await requireUnpairOperationOwner(uid, operation);
  return publicUnpairOperation(operation);
});

/** Owner-only manual retry; scheduled retries also run every minute. */
export const retryMainControllerUnpair = onCall(
  { secrets: mainControllerMqttSecrets },
  async (request) => {
    const uid = requireAuthenticated(request);
    const input = callableInput(request.data);
    const operationId = validateUnpairOperationId(input.operationId);
    const ref = getFirestore().collection("controllerUnpairOperations").doc(operationId);
    const snapshot = await ref.get();
    const operation = snapshot.data();
    if (!snapshot.exists || !operation) throw new HttpsError("not-found", "Unpair operation was not found.");
    await requireUnpairOperationOwner(uid, operation);
    if (operation.status !== "pending" && operation.status !== "prepared") {
      throw new HttpsError("failed-precondition", "Unpair operation is not retryable.");
    }
    try {
      await publishUnpairOperation(operationId);
    } catch (error) {
      logger.warn("Manual Main Controller unpair retry failed", {
        operationId,
        code: error instanceof Error ? error.name : "unknown",
      });
    }
    const refreshed = await ref.get();
    return publicUnpairOperation(refreshed.data() ?? {});
  },
);

/** Durable best-effort retry worker; duplicate messages are keyed by operationId. */
export const retryPendingMainControllerUnpairs = onSchedule(
  { schedule: "every 1 minutes", timeZone: "UTC", secrets: mainControllerMqttSecrets },
  async () => {
    const db = getFirestore();
    const now = new Date();
    const nowTimestamp = Timestamp.fromDate(now);
    const due = await db.collection("controllerUnpairOperations")
      .where("status", "in", ["pending", "prepared"])
      .where("nextDeliveryAt", "<=", nowTimestamp)
      .limit(100)
      .get();
    for (const doc of due.docs) {
      if (doc.data().status === "pending" &&
        doc.data().expiresAt?.toDate?.().getTime?.() <= now.getTime()) {
        await expireMainControllerUnpair({
          store: pairingStore(),
          operationId: doc.id,
          now,
          serverTimestamp: FieldValue.serverTimestamp(),
        });
        continue;
      }
      try {
        await publishUnpairOperation(doc.id);
      } catch (error) {
        logger.warn("Scheduled Main Controller unpair retry failed", {
          operationId: doc.id,
          code: error instanceof Error ? error.name : "unknown",
        });
      }
    }
    // Pending operations whose delivery is backed off past expiry still need
    // to fail safely. They retain registry ownership and may be retried afresh.
    const expired = await db.collection("controllerUnpairOperations")
      .where("status", "==", "pending")
      .where("expiresAt", "<=", nowTimestamp)
      .limit(100)
      .get();
    for (const doc of expired.docs) {
      await expireMainControllerUnpair({
        store: pairingStore(),
        operationId: doc.id,
        now,
        serverTimestamp: FieldValue.serverTimestamp(),
      });
    }
  },
);

async function authenticatedIdentity(
  uid: string,
  request: CallableRequest<unknown>,
) {
  const authUser = await getAuth().getUser(uid);
  const token: Record<string, unknown> = request.auth?.token ?? {};
  return {
    uid,
    email: authUser.email ?? (typeof token.email === "string" ? token.email : ""),
    avatarUrl: authUser.photoURL ?? (typeof token.picture === "string" ? token.picture : null),
  };
}

function registrationDisplayName(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.trim().length > 100) {
    throw new HttpsError("invalid-argument", "Enter a valid name.");
  }
  return value.trim();
}

function makeJoinCode(): string {
  return randomInt(100000, 1000000).toString();
}

/** Creates an owner profile and both uniqueness indexes atomically. */
export const registerOwner = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  try {
    const data = request.data as Record<string, unknown> | null;
    const name = registrationDisplayName(data?.name);
    const houseName = normalizeHouseName(data?.houseName);
    const identity = await authenticatedIdentity(uid, request);
    const db = getFirestore();
    const userRef = db.collection("users").doc(uid);
    const houseRef = db.collection("houses").doc(uid);
    const nameRef = db.collection("houseNames").doc(houseNameIndexKey(houseName));

    // The normalized index is the canonical uniqueness check. The transaction
    // serializes registrations without scanning every existing owner profile.
    for (let attempt = 0; attempt < 8; attempt++) {
      const joinCode = makeJoinCode();
      const codeRef = db.collection("joinCodes").doc(joinCode);
      const result = await db.runTransaction(async (transaction) => {
        const userDoc = await transaction.get(userRef);
        const nameDoc = await transaction.get(nameRef);
        const codeDoc = await transaction.get(codeRef);
        const houseDoc = await transaction.get(houseRef);
        if (userDoc.exists) return { kind: "profile" as const };
        if (nameDoc.exists) return { kind: "house-name" as const };
        if (codeDoc.exists) return { kind: "join-code" as const };

        const existingHouse = houseDoc.data();
        if (houseDoc.exists && houseRegistryConflict(
          uid,
          { ownerUid: uid, name: houseName },
          existingHouse ?? {},
        )) {
          return { kind: "house-conflict" as const };
        }

        const profile = buildOwnerProfile({
          identity,
          displayName: name,
          houseName,
          joinCode,
        });
        transaction.create(userRef, profile);
        if (!houseDoc.exists) {
          transaction.create(houseRef, {
            ...buildHouseRegistryEntry(uid, uid, houseName),
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
        transaction.create(codeRef, { ownerId: uid, houseName });
        transaction.create(nameRef, { ownerId: uid });
        return { kind: "created" as const, profile };
      });

      if (result.kind === "join-code") continue;
      if (result.kind === "profile") {
        throw new HttpsError("already-exists", "This account is already registered. Please sign in.");
      }
      if (result.kind === "house-name") {
        throw new HttpsError("already-exists", "That House name is unavailable. Choose another name.");
      }
      if (result.kind === "house-conflict") {
        throw new HttpsError(
          "failed-precondition",
          "A conflicting House registry record already exists for this account. Contact support.",
        );
      }
      return { user: result.profile };
    }
    throw new HttpsError("resource-exhausted", "Registration could not be completed. Please try again.");
  } catch (error) {
    safeRegistrationError(error);
  }
});

/** Validates the invitation and creates a pending member profile atomically. */
export const registerMember = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  try {
    const data = request.data as Record<string, unknown> | null;
    const code = typeof data?.joinCode === "string" ? data.joinCode.trim() : "";
    if (!/^\d{6}$/.test(code)) {
      throw new RegistrationDomainError("invalid-join-code");
    }
    const name = registrationDisplayName(data?.name);
    const identity = await authenticatedIdentity(uid, request);
    const db = getFirestore();
    const userRef = db.collection("users").doc(uid);
    const codeRef = db.collection("joinCodes").doc(code);

    const profile = await db.runTransaction(async (transaction) => {
      const userDoc = await transaction.get(userRef);
      assertProfileDoesNotExist(userDoc.exists);
      const codeDoc = await transaction.get(codeRef);
      const ownerUid = codeDoc.data()?.ownerId;
      if (typeof ownerUid !== "string" || !ownerUid) {
        throw new RegistrationDomainError("invalid-join-code");
      }
      const ownerDoc = await transaction.get(db.collection("users").doc(ownerUid));
      const member = buildMemberProfile({
        identity,
        displayName: name,
        joinCodeDocument: codeDoc.data() ?? null,
        ownerProfile: ownerDoc.data() ?? null,
      });
      transaction.create(userRef, member);
      return member;
    });
    return { user: profile };
  } catch (error) {
    safeRegistrationError(error);
  }
});

/** Server-side repair for legacy owner join-code and House-name indexes. */
export const ensureOwnerIndexes = onCall(async (request) => {
  const uid = requireAuthenticated(request);
  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  for (let attempt = 0; attempt < 8; attempt++) {
    const userSnapshot = await userRef.get();
    const user = userSnapshot.data();
    if (!user || user.id !== uid || user.role !== "owner" || user.houseId !== uid) {
      throw new HttpsError("permission-denied", "Owner profile is required.");
    }
    const houseName = normalizeHouseName(user.houseName);
    const nameRef = db.collection("houseNames").doc(houseNameIndexKey(houseName));
    const oldCode = typeof user.joinCode === "string" && /^\d{6}$/.test(user.joinCode)
      ? user.joinCode
      : null;
    const joinCode = oldCode ?? makeJoinCode();
    const codeRef = db.collection("joinCodes").doc(joinCode);
    const result = await db.runTransaction(async (transaction) => {
      const currentUser = await transaction.get(userRef);
      const current = currentUser.data();
      const nameDoc = await transaction.get(nameRef);
      const codeDoc = await transaction.get(codeRef);
      if (!currentUser.exists || current?.role !== "owner" || current.id !== uid || current.houseId !== uid) {
        return { kind: "invalid-profile" as const };
      }
      if (nameDoc.exists && nameDoc.data()?.ownerId !== uid) {
        return { kind: "name-conflict" as const, joinCode: current.joinCode };
      }
      if (codeDoc.exists && codeDoc.data()?.ownerId !== uid) {
        return { kind: "code-collision" as const };
      }
      if (!nameDoc.exists) transaction.create(nameRef, { ownerId: uid });
      if (!codeDoc.exists) transaction.create(codeRef, { ownerId: uid, houseName });
      if (current.joinCode !== joinCode) transaction.update(userRef, { joinCode });
      return { kind: "ok" as const, joinCode };
    });

    if (result.kind === "code-collision") continue;
    if (result.kind === "invalid-profile") {
      throw new HttpsError("permission-denied", "Owner profile is required.");
    }
    if (result.kind === "name-conflict") {
      return { joinCode: result.joinCode ?? null, houseNameIndexed: false };
    }
    return { joinCode: result.joinCode, houseNameIndexed: true };
  }
  throw new HttpsError("resource-exhausted", "Owner indexes could not be repaired. Please try again.");
});

/**
 * Explicit, operator-only, dry-run-first backfill for legacy owner profiles.
 * This does not pair controllers or Nodes and is never run automatically.
 */
export const migrateLegacyHouses = onCall(async (request) => {
  requireHouseMigrationAdmin(request);
  const input = request.data;
  const dryRun =
    typeof input !== "object" ||
    input === null ||
    (input as Record<string, unknown>).dryRun !== false;

  const db = getFirestore();
  const [ownerSnapshot, houseSnapshot] = await Promise.all([
    db.collection("users").where("role", "==", "owner").get(),
    db.collection("houses").get(),
  ]);
  const issues: Array<{ profileId: string; reason: string }> = [];
  const existingHouseIds: string[] = [];
  const conflicts: Array<{ houseId: string; reason: string }> = [];
  const failures: Array<{ houseId: string; reason: string }> = [];
  const existingHouses = new Map(
    houseSnapshot.docs.map((doc) => [doc.id, doc.data()] as const),
  );
  const validOwners: Array<{ uid: string; name: string }> = [];

  for (const doc of ownerSnapshot.docs) {
    const data = doc.data();
    const uid = doc.id;
    if (data.id !== uid || data.houseId !== uid) {
      issues.push({
        profileId: uid,
        reason: "Owner profile identity or legacy House ID is inconsistent.",
      });
      continue;
    }
    if (typeof data.houseName !== "string" || !data.houseName.trim()) {
      issues.push({ profileId: uid, reason: "Owner profile has no usable houseName." });
      continue;
    }
    validOwners.push({ uid, name: data.houseName.trim() });
  }

  const idsByName = new Map<string, string[]>();
  for (const owner of validOwners) {
    const normalized = owner.name.toLowerCase();
    idsByName.set(normalized, [...(idsByName.get(normalized) ?? []), owner.uid]);
  }
  const duplicateNameIds = new Set<string>();
  for (const ids of idsByName.values()) {
    if (ids.length < 2) continue;
    for (const uid of ids) {
      duplicateNameIds.add(uid);
      issues.push({
        profileId: uid,
        reason: "Multiple legacy owner profiles use the same houseName.",
      });
    }
  }

  const candidates = validOwners.filter((owner) => {
    if (duplicateNameIds.has(owner.uid)) return false;
    const existing = existingHouses.get(owner.uid);
    if (existing) {
      const conflict = houseRegistryConflict(
        owner.uid,
        { ownerUid: owner.uid, name: owner.name },
        existing,
      );
      if (conflict) conflicts.push({ houseId: owner.uid, reason: conflict });
      else existingHouseIds.push(owner.uid);
      return false;
    }
    return true;
  });

  let created = 0;
  let alreadyExists = existingHouseIds.length;
  if (!dryRun) {
    for (const candidate of candidates) {
      const userRef = db.collection("users").doc(candidate.uid);
      const houseRef = db.collection("houses").doc(candidate.uid);
      try {
        const result = await db.runTransaction(async (transaction) => {
          const userDoc = await transaction.get(userRef);
          const houseDoc = await transaction.get(houseRef);
          if (houseDoc.exists) {
            const conflict = houseRegistryConflict(
              candidate.uid,
              { ownerUid: candidate.uid, name: candidate.name },
              houseDoc.data() ?? {},
            );
            return conflict ? { kind: "conflict" as const, reason: conflict } : { kind: "exists" as const };
          }
          const user = userDoc.data();
          if (
            !userDoc.exists ||
            user?.role !== "owner" ||
            user.id !== candidate.uid ||
            user.houseId !== candidate.uid ||
            typeof user.houseName !== "string" ||
            user.houseName.trim() !== candidate.name
          ) {
            return { kind: "changed" as const };
          }
          transaction.create(houseRef, {
            houseId: candidate.uid,
            ownerUid: candidate.uid,
            name: candidate.name,
            mainControllerId: null,
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          return { kind: "created" as const };
        });
        if (result.kind === "created") created++;
        if (result.kind === "exists") alreadyExists++;
        if (result.kind === "conflict") conflicts.push({ houseId: candidate.uid, reason: result.reason });
        if (result.kind === "changed") failures.push({
          houseId: candidate.uid,
          reason: "Owner profile changed after planning; House was not created.",
        });
      } catch (_) {
        failures.push({
          houseId: candidate.uid,
          reason: "House creation failed; review the record and retry the migration.",
        });
      }
    }
  }

  return {
    dryRun,
    plannedCount: candidates.length,
    createdCount: created,
    alreadyExistsCount: alreadyExists,
    conflicts,
    failures,
    candidates: candidates.map(({ uid, name }) => ({ houseId: uid, ownerUid: uid, name })),
    issues,
  };
});
