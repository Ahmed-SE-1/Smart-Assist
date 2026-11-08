import { createHash } from "node:crypto";

export type PairingErrorCode =
  | "invalid-argument"
  | "permission-denied"
  | "not-found"
  | "already-exists"
  | "failed-precondition";

export class PairingError extends Error {
  constructor(readonly code: PairingErrorCode, message: string) {
    super(message);
    this.name = "PairingError";
  }
}

export interface PairingSnapshot {
  readonly exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface PairingTransaction {
  get(ref: object): Promise<PairingSnapshot>;
  create(ref: object, data: Record<string, unknown>): void;
  update(ref: object, data: Record<string, unknown>): void;
}

export interface PairingStore {
  doc(collection: string, id: string): object;
  runTransaction<T>(operation: (transaction: PairingTransaction) => Promise<T>): Promise<T>;
}

export type UnpairStatus = "pending" | "prepared" | "completed" | "failed";

export interface MainControllerUnpairOperation {
  operationId: string;
  houseId: string;
  controllerId: string;
  requestedBy: string;
  createdAt: unknown;
  updatedAt: unknown;
  expiresAt: unknown;
  status: UnpairStatus;
  deliveryAttempts: number;
  nextDeliveryAt: unknown;
  [key: string]: unknown;
}

export function hashPairingToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function hashControllerRecoverySecret(secret: string): string {
  return createHash("sha256").update(validateControllerRecoverySecret(secret), "utf8").digest("hex");
}

export function validateControllerRecoverySecret(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new PairingError("invalid-argument", "Controller recovery authorization is invalid.");
  }
  return value;
}

export function validatePairingToken(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new PairingError("invalid-argument", "A valid pairing token is required.");
  }
  return value;
}

/** Controller IDs use a stable CTRL_ prefix and an opaque 8–56 char suffix. */
export function validateControllerId(value: unknown): string {
  if (typeof value !== "string" || !/^CTRL_[A-Za-z0-9_-]{8,56}$/.test(value)) {
    throw new PairingError("invalid-argument", "Controller ID format is invalid.");
  }
  return value;
}

/** New Main ESP32 identities use the stable eFuse/base MAC, normalized lowercase. */
export function validateMacDerivedControllerId(value: unknown): string {
  if (typeof value !== "string" || !/^CTRL_[0-9a-f]{12}$/.test(value)) {
    throw new PairingError(
      "invalid-argument",
      "New Main Controller IDs must be CTRL_ followed by the lowercase 12-digit MAC.",
    );
  }
  return value;
}

export function controllerFirebaseAuthUid(controllerId: string): string {
  return `smartassist-controller-${validateControllerId(controllerId)}`;
}

/** Keep retries in one in-progress generation; a revoked identity re-pair gets a new one. */
export function nextControllerCredentialGeneration(
  currentGeneration: unknown,
  credentialStatus: unknown,
): number {
  const current = Number.isInteger(currentGeneration) && Number(currentGeneration) >= 0
    ? Number(currentGeneration) : 0;
  return credentialStatus === "provisioning" || credentialStatus === "active"
    ? Math.max(1, current)
    : current + 1;
}

export function validateControllerIdentityClaims(args: {
  uid: string;
  controllerId: string;
  claims: Record<string, unknown>;
  expectedAuthUid: string;
  expectedGeneration: number;
  credentialStatus: unknown;
  operationStatus: unknown;
  operationControllerId: unknown;
  operationHouseId: unknown;
  assignedHouseId: unknown;
  nowSeconds: number;
  tokensValidAfterSeconds: number;
}): void {
  const claims = args.claims;
  const completedReplay =
    args.operationStatus === "completed" && args.credentialStatus === "revoked";
  if (
    args.uid !== args.expectedAuthUid ||
    args.operationControllerId !== args.controllerId ||
    (args.operationHouseId !== args.assignedHouseId &&
      !(completedReplay && args.assignedHouseId == null)) ||
    claims.deviceType !== "main-controller" ||
    claims.controllerId !== args.controllerId ||
    claims.credentialGeneration !== args.expectedGeneration ||
    (args.credentialStatus !== "active" && !completedReplay) ||
    typeof claims.exp !== "number" || claims.exp <= args.nowSeconds ||
    typeof claims.auth_time !== "number" ||
    (!completedReplay && claims.auth_time < args.tokensValidAfterSeconds)
  ) {
    throw new PairingError("permission-denied", "Controller credential is invalid or revoked.");
  }
}

function assertApprovedOwner(
  uid: string,
  houseId: string,
  profile: Record<string, unknown> | undefined,
  house: Record<string, unknown> | undefined,
): void {
  if (
    !profile || profile.id !== uid || profile.role !== "owner" ||
    profile.houseId !== houseId || profile.isApproved !== true ||
    !house || house.houseId !== houseId || house.ownerUid !== uid
  ) {
    throw new PairingError("permission-denied", "Approved House owner access is required.");
  }
}

export async function createPairingSession(args: {
  store: PairingStore;
  uid: string;
  houseId: string;
  token: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<{ houseId: string; expiresAt: Date }> {
  const houseId = validateHouseId(args.houseId);
  const token = validatePairingToken(args.token);
  const tokenHash = hashPairingToken(token);
  const userRef = args.store.doc("users", args.uid);
  const houseRef = args.store.doc("houses", houseId);
  const sessionRef = args.store.doc("pairingSessions", tokenHash);
  const expiresAt = new Date(args.now.getTime() + 5 * 60 * 1000);

  await args.store.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const houseSnapshot = await transaction.get(houseRef);
    const sessionSnapshot = await transaction.get(sessionRef);
    const user = userSnapshot.data();
    const house = houseSnapshot.data();
    assertApprovedOwner(args.uid, houseId, user, house);
    if (house?.mainControllerId != null || house?.pendingUnpairOperationId != null) {
      throw new PairingError("already-exists", "This House already has a Main Controller.");
    }
    if (sessionSnapshot.exists) {
      throw new PairingError("already-exists", "Pairing session could not be created. Try again.");
    }
    transaction.create(sessionRef, {
      tokenHash,
      houseId,
      ownerUid: args.uid,
      createdAt: args.serverTimestamp,
      expiresAt,
      consumedAt: null,
    });
  });

  return { houseId, expiresAt };
}

export async function claimMainController(args: {
  store: PairingStore;
  token: string;
  controllerId: string;
  recoverySecret: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<{ houseId: string; controllerId: string }> {
  const token = validatePairingToken(args.token);
  const controllerId = validateControllerId(args.controllerId);
  const recoverySecretHash = hashControllerRecoverySecret(args.recoverySecret);
  const tokenHash = hashPairingToken(token);
  const sessionRef = args.store.doc("pairingSessions", tokenHash);
  const recoveryRef = args.store.doc("controllerCredentialRecoverySessions", recoverySecretHash);

  return args.store.runTransaction(async (transaction) => {
    const sessionSnapshot = await transaction.get(sessionRef);
    if (!sessionSnapshot.exists) {
      throw new PairingError("permission-denied", "Pairing token is invalid or expired.");
    }
    const session = sessionSnapshot.data();
    const houseId = typeof session?.houseId === "string" ? session.houseId : "";
    const ownerUid = typeof session?.ownerUid === "string" ? session.ownerUid : "";
    if (!houseId || !ownerUid || session?.tokenHash !== tokenHash) {
      throw new PairingError("permission-denied", "Pairing token is invalid or expired.");
    }

    const houseRef = args.store.doc("houses", houseId);
    const userRef = args.store.doc("users", ownerUid);
    const controllerRef = args.store.doc("controllers", controllerId);
    const ownerSnapshot = await transaction.get(userRef);
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    const recoverySnapshot = await transaction.get(recoveryRef);
    const house = houseSnapshot.data();
    const controller = controllerSnapshot.data();
    assertApprovedOwner(ownerUid, houseId, ownerSnapshot.data(), house);
    const expiresAtMillis = dateMillis(session?.expiresAt);
    if (session?.consumedAt != null) {
      // An owner token replay can restore a lost claim response only while the
      // original assignment, generation, and recovery window still match.
      const recoveryUntil = dateMillis(session?.recoveryExpiresAt);
      if (
        Number.isFinite(recoveryUntil) && recoveryUntil > args.now.getTime() &&
        session.claimedControllerId === controllerId &&
        house?.mainControllerId === controllerId &&
        controller?.activeHouseId === houseId &&
        Number.isInteger(session.credentialGeneration) &&
        nextControllerCredentialGeneration(
          controller?.authCredentialGeneration,
          controller?.authCredentialStatus,
        ) === session.credentialGeneration
      ) {
        if (recoverySnapshot.exists) {
          const recovery = recoverySnapshot.data();
          if (recovery?.secretHash !== recoverySecretHash ||
            recovery.controllerId !== controllerId || recovery.houseId !== houseId ||
            recovery.credentialGeneration !== session.credentialGeneration) {
            throw new PairingError("failed-precondition", "Recovery authorization is already in use.");
          }
        } else {
          transaction.create(recoveryRef, {
            secretHash: recoverySecretHash,
            controllerId,
            houseId,
            credentialGeneration: session.credentialGeneration,
            expiresAt: session.recoveryExpiresAt,
            createdAt: args.serverTimestamp,
          });
        }
        return { houseId, controllerId };
      }
      throw new PairingError("failed-precondition", "Pairing token has already been used.");
    }
    if (!Number.isFinite(expiresAtMillis) || expiresAtMillis <= args.now.getTime()) {
      throw new PairingError("permission-denied", "Pairing token is invalid or expired.");
    }
    if (!houseSnapshot.exists || house?.houseId !== houseId || house.ownerUid !== ownerUid) {
      throw new PairingError("failed-precondition", "Pairing House is no longer available.");
    }
    if (house.mainControllerId != null) {
      throw new PairingError("already-exists", "This House already has a Main Controller.");
    }
    if (
      controllerSnapshot.exists &&
      (controller?.activeHouseId != null ||
        (controller?.controllerId != null && controller.controllerId !== controllerId))
    ) {
      throw new PairingError("already-exists", "This controller is already assigned.");
    }

    transaction.update(houseRef, {
      mainControllerId: controllerId,
      pendingUnpairOperationId: null,
      lastUnpairOperationId: null,
      updatedAt: args.serverTimestamp,
    });
    if (controllerSnapshot.exists) {
      transaction.update(controllerRef, {
        controllerId,
        activeHouseId: houseId,
        status: "paired",
        pairedAt: args.serverTimestamp,
        pendingUnpairOperationId: null,
      });
    } else {
      transaction.create(controllerRef, {
        controllerId,
        activeHouseId: houseId,
        status: "paired",
        pairedAt: args.serverTimestamp,
        lastSeenAt: null,
        pendingUnpairOperationId: null,
      });
    }
    transaction.update(sessionRef, {
      consumedAt: args.serverTimestamp,
      claimedControllerId: controllerId,
      credentialGeneration: nextControllerCredentialGeneration(
        controller?.authCredentialGeneration,
        controller?.authCredentialStatus,
      ),
      recoveryExpiresAt: new Date(args.now.getTime() + 10 * 60 * 1000),
    });
    transaction.create(recoveryRef, {
      secretHash: recoverySecretHash,
      controllerId,
      houseId,
      credentialGeneration: nextControllerCredentialGeneration(
        controller?.authCredentialGeneration,
        controller?.authCredentialStatus,
      ),
      expiresAt: new Date(args.now.getTime() + 10 * 60 * 1000),
      createdAt: args.serverTimestamp,
    });
    return { houseId, controllerId };
  });
}

/** Validates the device-generated, short-lived capability issued atomically with the claim. */
export async function recoverMainControllerCredential(args: {
  store: PairingStore;
  recoverySecret: string;
  controllerId: string;
  now: Date;
}): Promise<{ houseId: string; controllerId: string; credentialGeneration: number }> {
  const controllerId = validateControllerId(args.controllerId);
  const secretHash = hashControllerRecoverySecret(args.recoverySecret);
  const recoveryRef = args.store.doc("controllerCredentialRecoverySessions", secretHash);
  const controllerRef = args.store.doc("controllers", controllerId);

  return args.store.runTransaction(async (transaction) => {
    const [recoverySnapshot, controllerSnapshot] = await Promise.all([
      transaction.get(recoveryRef),
      transaction.get(controllerRef),
    ]);
    const recovery = recoverySnapshot.data();
    const controller = controllerSnapshot.data();
    const expiresAt = dateMillis(recovery?.expiresAt);
    if (!recoverySnapshot.exists || !controllerSnapshot.exists ||
      recovery?.secretHash !== secretHash || recovery.controllerId !== controllerId ||
      typeof recovery.houseId !== "string" || !Number.isInteger(recovery.credentialGeneration) ||
      !Number.isFinite(expiresAt) || expiresAt <= args.now.getTime() ||
      controller?.controllerId !== controllerId || controller.activeHouseId !== recovery.houseId ||
      nextControllerCredentialGeneration(
        controller.authCredentialGeneration,
        controller.authCredentialStatus,
      ) !== recovery.credentialGeneration || controller.pendingUnpairOperationId != null) {
      throw new PairingError("permission-denied", "Controller recovery authorization is invalid or expired.");
    }
    return {
      houseId: recovery.houseId,
      controllerId,
      credentialGeneration: recovery.credentialGeneration as number,
    };
  });
}

export async function createControllerIdentityMigrationSession(args: {
  store: PairingStore;
  uid: string;
  houseId: string;
  controllerId: string;
  token: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<{ houseId: string; controllerId: string; expiresAt: Date }> {
  const houseId = validateHouseId(args.houseId);
  const controllerId = validateControllerId(args.controllerId);
  const token = validatePairingToken(args.token);
  const tokenHash = hashPairingToken(token);
  const userRef = args.store.doc("users", args.uid);
  const houseRef = args.store.doc("houses", houseId);
  const controllerRef = args.store.doc("controllers", controllerId);
  const sessionRef = args.store.doc("controllerIdentityMigrationSessions", tokenHash);
  const expiresAt = new Date(args.now.getTime() + 5 * 60 * 1000);

  await args.store.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    const sessionSnapshot = await transaction.get(sessionRef);
    const house = houseSnapshot.data();
    const controller = controllerSnapshot.data();
    assertApprovedOwner(args.uid, houseId, userSnapshot.data(), house);
    if (
      !controllerSnapshot.exists || house?.mainControllerId !== controllerId ||
      controller?.activeHouseId !== houseId ||
      house?.pendingUnpairOperationId != null
    ) {
      throw new PairingError("failed-precondition", "The controller is not available for identity migration.");
    }
    if (controller?.authCredentialStatus === "active") {
      throw new PairingError("already-exists", "This controller already has a Firebase identity.");
    }
    if (sessionSnapshot.exists) {
      throw new PairingError("already-exists", "Identity migration session could not be created.");
    }
    transaction.create(sessionRef, {
      tokenHash,
      ownerUid: args.uid,
      houseId,
      controllerId,
      createdAt: args.serverTimestamp,
      expiresAt,
      consumedAt: null,
    });
  });
  return { houseId, controllerId, expiresAt };
}

export async function consumeControllerIdentityMigrationSession(args: {
  store: PairingStore;
  token: string;
  controllerId: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<{ houseId: string; controllerId: string; ownerUid: string }> {
  const token = validatePairingToken(args.token);
  const controllerId = validateControllerId(args.controllerId);
  const tokenHash = hashPairingToken(token);
  const sessionRef = args.store.doc("controllerIdentityMigrationSessions", tokenHash);
  return args.store.runTransaction(async (transaction) => {
    const sessionSnapshot = await transaction.get(sessionRef);
    const session = sessionSnapshot.data();
    if (!sessionSnapshot.exists || session?.tokenHash !== tokenHash ||
      session?.controllerId !== controllerId) {
      throw new PairingError("permission-denied", "Identity migration token is invalid or expired.");
    }
    const houseId = validateHouseId(session.houseId);
    const ownerUid = typeof session.ownerUid === "string" ? session.ownerUid : "";
    const userRef = args.store.doc("users", ownerUid);
    const houseRef = args.store.doc("houses", houseId);
    const controllerRef = args.store.doc("controllers", controllerId);
    const userSnapshot = await transaction.get(userRef);
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    const house = houseSnapshot.data();
    const controller = controllerSnapshot.data();
    assertApprovedOwner(ownerUid, houseId, userSnapshot.data(), house);
    const expiryMillis = dateMillis(session.expiresAt);
    if (
      !Number.isFinite(expiryMillis) || expiryMillis <= args.now.getTime() ||
      !controllerSnapshot.exists || house?.mainControllerId !== controllerId ||
      controller?.activeHouseId !== houseId || house?.pendingUnpairOperationId != null
    ) {
      throw new PairingError("permission-denied", "Identity migration token is invalid or expired.");
    }
    if (session.consumedAt != null && session.consumedControllerId !== controllerId) {
      throw new PairingError("failed-precondition", "Identity migration token was already used.");
    }
    if (session.consumedAt == null) {
      transaction.update(sessionRef, {
        consumedAt: args.serverTimestamp,
        consumedControllerId: controllerId,
      });
    }
    return { houseId, controllerId, ownerUid };
  });
}

export async function requestMainControllerUnpair(args: {
  store: PairingStore;
  uid: string;
  houseId: string;
  controllerId: string;
  operationId: string;
  now: Date;
  expiresAt: Date;
  serverTimestamp: unknown;
}): Promise<MainControllerUnpairOperation> {
  const houseId = validateHouseId(args.houseId);
  const controllerId = validateControllerId(args.controllerId);
  validateUnpairOperationId(args.operationId);
  const userRef = args.store.doc("users", args.uid);
  const houseRef = args.store.doc("houses", houseId);
  const controllerRef = args.store.doc("controllers", controllerId);
  const operationRef = args.store.doc("controllerUnpairOperations", args.operationId);

  return args.store.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    const house = houseSnapshot.data();
    const controller = controllerSnapshot.data();
    assertApprovedOwner(args.uid, houseId, userSnapshot.data(), house);

    const activeId = house?.pendingUnpairOperationId;
    const lastId = house?.lastUnpairOperationId;
    const existingId = typeof activeId === "string" ? activeId :
      typeof lastId === "string" ? lastId : null;
    const existingRef = existingId
      ? args.store.doc("controllerUnpairOperations", existingId)
      : null;
    const existingSnapshot = existingRef ? await transaction.get(existingRef) : null;
    const existing = existingSnapshot?.data();
    if (
      existingSnapshot?.exists && existing?.houseId === houseId &&
      existing.controllerId === controllerId &&
      (existing.status === "prepared" || existing.status === "completed" ||
        (existing.status === "pending" && dateMillis(existing.expiresAt) > args.now.getTime()))
    ) {
      if (existing.status !== "completed" && (
        !controllerSnapshot.exists || house?.mainControllerId !== controllerId ||
        controller?.activeHouseId !== houseId ||
        house?.pendingUnpairOperationId !== existing.operationId ||
        controller?.pendingUnpairOperationId !== existing.operationId
      )) {
        throw new PairingError("failed-precondition", "Unpair registry assignment changed.");
      }
      return existing as unknown as MainControllerUnpairOperation;
    }

    if (
      !controllerSnapshot.exists || house?.mainControllerId !== controllerId ||
      controller?.activeHouseId !== houseId ||
      (controller?.controllerId != null && controller.controllerId !== controllerId)
    ) {
      throw new PairingError("failed-precondition", "The controller is not paired to this House.");
    }
    if (activeId != null && existing?.status !== "failed" &&
      !(existing?.status === "pending" && dateMillis(existing.expiresAt) <= args.now.getTime())) {
      throw new PairingError("already-exists", "A controller operation is already active.");
    }
    if (existingSnapshot?.exists && existing?.status === "pending") {
      transaction.update(existingRef!, {
        status: "failed",
        failureCode: "expired",
        updatedAt: args.serverTimestamp,
      });
    }

    const operation: MainControllerUnpairOperation = {
      operationId: args.operationId,
      houseId,
      controllerId,
      requestedBy: args.uid,
      createdAt: args.serverTimestamp,
      updatedAt: args.serverTimestamp,
      expiresAt: args.expiresAt,
      status: "pending",
      deliveryAttempts: 0,
      nextDeliveryAt: args.now,
    };
    transaction.create(operationRef, operation);
    transaction.update(houseRef, {
      pendingUnpairOperationId: args.operationId,
      lastUnpairOperationId: args.operationId,
      updatedAt: args.serverTimestamp,
    });
    transaction.update(controllerRef, {
      pendingUnpairOperationId: args.operationId,
      status: "unpair_pending",
    });
    return operation;
  });
}

export async function acknowledgeMainControllerUnpairPrepared(args: {
  store: PairingStore;
  operationId: string;
  controllerId: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<MainControllerUnpairOperation> {
  return acknowledgeUnpair(args, "prepared");
}

export async function acknowledgeMainControllerUnpairCompleted(args: {
  store: PairingStore;
  operationId: string;
  controllerId: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<MainControllerUnpairOperation> {
  return acknowledgeUnpair(args, "completed");
}

async function acknowledgeUnpair(
  args: {
    store: PairingStore;
    operationId: string;
    controllerId: string;
    now: Date;
    serverTimestamp: unknown;
  },
  target: "prepared" | "completed",
): Promise<MainControllerUnpairOperation> {
  const controllerId = validateControllerId(args.controllerId);
  validateUnpairOperationId(args.operationId);
  const operationRef = args.store.doc("controllerUnpairOperations", args.operationId);
  return args.store.runTransaction(async (transaction) => {
    const operationSnapshot = await transaction.get(operationRef);
    const operation = operationSnapshot.data();
    if (!operationSnapshot.exists || operation?.controllerId !== controllerId ||
      operation.operationId !== args.operationId) {
      throw new PairingError("not-found", "Unpair operation was not found.");
    }
    if (target === "completed" && operation.status === "completed") {
      return operation as unknown as MainControllerUnpairOperation;
    }
    const duplicatePrepared = target === "prepared" && operation.status === "prepared";
    if (operation.status === "failed") {
      throw new PairingError("failed-precondition", "Unpair operation is no longer active.");
    }
    if ((target === "prepared" && operation.status !== "pending" && !duplicatePrepared) ||
      (target === "completed" && operation.status !== "prepared")) {
      throw new PairingError("failed-precondition", "Unpair acknowledgement is out of order.");
    }
    // Expiry gates the physical prepare; prepared operations remain retryable
    // until completion so a lost MQTT acknowledgement cannot release a device.
    if (operation.status === "pending" && dateMillis(operation.expiresAt) <= args.now.getTime()) {
      throw new PairingError("failed-precondition", "Unpair operation has expired.");
    }

    const houseId = validateHouseId(operation.houseId);
    const houseRef = args.store.doc("houses", houseId);
    const controllerRef = args.store.doc("controllers", controllerId);
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    const house = houseSnapshot.data();
    const controller = controllerSnapshot.data();
    if (!houseSnapshot.exists || !controllerSnapshot.exists ||
      house?.mainControllerId !== controllerId || controller?.activeHouseId !== houseId ||
      house?.pendingUnpairOperationId !== args.operationId ||
      controller?.pendingUnpairOperationId !== args.operationId) {
      throw new PairingError("failed-precondition", "Unpair registry assignment changed.");
    }

    if (duplicatePrepared) {
      return operation as unknown as MainControllerUnpairOperation;
    }

    if (target === "prepared") {
      transaction.update(operationRef, {
        status: "prepared",
        preparedAt: args.serverTimestamp,
        updatedAt: args.serverTimestamp,
        nextDeliveryAt: args.now,
      });
      transaction.update(controllerRef, { status: "unpair_prepared" });
      return { ...operation, status: "prepared" } as unknown as MainControllerUnpairOperation;
    }

    transaction.update(houseRef, {
      mainControllerId: null,
      pendingUnpairOperationId: null,
      updatedAt: args.serverTimestamp,
    });
    transaction.update(controllerRef, {
      activeHouseId: null,
      pendingUnpairOperationId: null,
      status: "unpaired",
      authCredentialStatus: "revoked",
      authCredentialRevokedAt: args.serverTimestamp,
    });
    transaction.update(operationRef, {
      status: "completed",
      completedAt: args.serverTimestamp,
      updatedAt: args.serverTimestamp,
    });
    return { ...operation, status: "completed" } as unknown as MainControllerUnpairOperation;
  });
}

export async function expireMainControllerUnpair(args: {
  store: PairingStore;
  operationId: string;
  now: Date;
  serverTimestamp: unknown;
}): Promise<boolean> {
  validateUnpairOperationId(args.operationId);
  const operationRef = args.store.doc("controllerUnpairOperations", args.operationId);
  return args.store.runTransaction(async (transaction) => {
    const opSnapshot = await transaction.get(operationRef);
    const op = opSnapshot.data();
    if (!opSnapshot.exists || op?.status !== "pending" || dateMillis(op.expiresAt) > args.now.getTime()) {
      return false;
    }
    const houseRef = args.store.doc("houses", String(op.houseId ?? ""));
    const controllerRef = args.store.doc("controllers", String(op.controllerId ?? ""));
    const houseSnapshot = await transaction.get(houseRef);
    const controllerSnapshot = await transaction.get(controllerRef);
    transaction.update(operationRef, {
      status: "failed",
      failureCode: "expired",
      updatedAt: args.serverTimestamp,
    });
    if (houseSnapshot.exists && houseSnapshot.data()?.pendingUnpairOperationId === args.operationId) {
      transaction.update(houseRef, { pendingUnpairOperationId: null, updatedAt: args.serverTimestamp });
    }
    if (controllerSnapshot.exists && controllerSnapshot.data()?.pendingUnpairOperationId === args.operationId) {
      transaction.update(controllerRef, { pendingUnpairOperationId: null, status: "paired" });
    }
    return true;
  });
}

export async function recordUnpairDeliveryAttempt(args: {
  store: PairingStore;
  operationId: string;
  nextDeliveryAt: Date;
  serverTimestamp: unknown;
}): Promise<UnpairStatus | null> {
  validateUnpairOperationId(args.operationId);
  const operationRef = args.store.doc("controllerUnpairOperations", args.operationId);
  return args.store.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(operationRef);
    const operation = snapshot.data();
    if (!snapshot.exists || (operation?.status !== "pending" && operation?.status !== "prepared")) {
      return null;
    }
    transaction.update(operationRef, {
      deliveryAttempts: Number(operation.deliveryAttempts ?? 0) + 1,
      lastDeliveryAt: args.serverTimestamp,
      nextDeliveryAt: args.nextDeliveryAt,
      updatedAt: args.serverTimestamp,
    });
    return operation.status;
  });
}

export function validateUnpairOperationId(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{32,64}$/.test(value)) {
    throw new PairingError("invalid-argument", "Unpair operation ID is invalid.");
  }
  return value;
}

function validateHouseId(value: unknown): string {
  if (
    typeof value !== "string" || !value.trim() || value.length > 128 ||
    value !== value.trim() || value.includes("/") || /[\u0000-\u001f]/.test(value)
  ) {
    throw new PairingError("invalid-argument", "House ID is invalid.");
  }
  return value;
}

function dateMillis(value: unknown): number {
  if (value instanceof Date) return value.getTime();
  if (
    typeof value === "object" && value !== null &&
    "toMillis" in value && typeof value.toMillis === "function"
  ) {
    return value.toMillis();
  }
  return Number.NaN;
}
