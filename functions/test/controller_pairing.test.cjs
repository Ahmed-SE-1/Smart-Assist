const test = require('node:test');
const assert = require('node:assert/strict');
const {
  claimMainController,
  recoverMainControllerCredential,
  consumeControllerIdentityMigrationSession,
  controllerFirebaseAuthUid,
  acknowledgeMainControllerUnpairCompleted,
  acknowledgeMainControllerUnpairPrepared,
  createControllerIdentityMigrationSession,
  createPairingSession,
  expireMainControllerUnpair,
  hashPairingToken,
  hashControllerRecoverySecret,
  nextControllerCredentialGeneration,
  validateControllerIdentityClaims,
  validateMacDerivedControllerId,
  recordUnpairDeliveryAttempt,
  requestMainControllerUnpair,
} = require('../lib/controller_pairing.js');

const now = new Date('2026-11-05T12:00:00.000Z');
const serverTime = 'SERVER_TIMESTAMP';
const token = (letter) => letter.repeat(43);
const recoverySecret = (letter) => letter.repeat(43);

class MemoryPairingStore {
  constructor() {
    this.documents = new Map();
    this.tail = Promise.resolve();
    this.failCommit = false;
  }

  doc(collection, id) {
    return { key: `${collection}/${id}` };
  }

  seed(collection, id, data) {
    this.documents.set(`${collection}/${id}`, structuredClone(data));
  }

  read(collection, id) {
    const value = this.documents.get(`${collection}/${id}`);
    return value === undefined ? undefined : structuredClone(value);
  }

  async runTransaction(operation) {
    const previous = this.tail;
    let release;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    const writes = [];
    const transaction = {
      get: async (ref) => {
        const value = this.documents.get(ref.key);
        return {
          exists: value !== undefined,
          data: () => value === undefined ? undefined : structuredClone(value),
        };
      },
      create: (ref, data) => writes.push({ kind: 'create', key: ref.key, data }),
      update: (ref, data) => writes.push({ kind: 'update', key: ref.key, data }),
    };
    try {
      const result = await operation(transaction);
      const next = new Map(this.documents);
      for (const write of writes) {
        if (write.kind === 'create' && next.has(write.key)) {
          throw new Error(`Document already exists: ${write.key}`);
        }
        if (write.kind === 'create') next.set(write.key, structuredClone(write.data));
        else {
          const current = next.get(write.key);
          if (!current) throw new Error(`Document missing: ${write.key}`);
          next.set(write.key, { ...current, ...structuredClone(write.data) });
        }
      }
      if (this.failCommit) {
        this.failCommit = false;
        throw new Error('Injected transaction commit failure');
      }
      this.documents = next;
      return result;
    } finally {
      release();
    }
  }
}

function seedOwner(store, uid, houseId = uid) {
  store.seed('users', uid, {
    id: uid,
    role: 'owner',
    houseId,
    isApproved: true,
  });
  store.seed('houses', houseId, {
    houseId,
    ownerUid: uid,
    name: `${houseId} Home`,
    mainControllerId: null,
  });
}

async function issueSession(store, uid, houseId, rawToken) {
  return createPairingSession({
    store,
    uid,
    houseId,
    token: rawToken,
    now,
    serverTimestamp: serverTime,
  });
}

async function claim(store, rawToken, controllerId, at = now) {
  return claimMainController({
    store,
    token: rawToken,
    controllerId,
    recoverySecret: recoverySecret('q'),
    now: at,
    serverTimestamp: serverTime,
  });
}

test('valid pairing assigns both registry records and stores only the token hash', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('a');
  const session = await issueSession(store, 'owner-a', 'owner-a', rawToken);
  assert.equal(session.expiresAt.getTime() - now.getTime(), 5 * 60 * 1000);

  const result = await claim(store, rawToken, 'CTRL_abcdefgh1234');
  assert.deepEqual(result, { houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234' });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
  const sessionDoc = store.read('pairingSessions', hashPairingToken(rawToken));
  assert.equal(sessionDoc.tokenHash, hashPairingToken(rawToken));
  assert.equal(JSON.stringify(sessionDoc).includes(rawToken), false);
  assert.equal(sessionDoc.consumedAt, serverTime);
});

test('new device identity format is stable and claims bind the Firebase user to one controller', () => {
  assert.equal(validateMacDerivedControllerId('CTRL_001122aabbcc'), 'CTRL_001122aabbcc');
  assert.throws(() => validateMacDerivedControllerId('CTRL_abcdefgh1234'), { code: 'invalid-argument' });
  assert.equal(controllerFirebaseAuthUid('CTRL_001122aabbcc'), 'smartassist-controller-CTRL_001122aabbcc');
  const valid = {
    uid: 'smartassist-controller-CTRL_001122aabbcc',
    controllerId: 'CTRL_001122aabbcc',
    claims: {
      deviceType: 'main-controller', controllerId: 'CTRL_001122aabbcc',
      credentialGeneration: 4, exp: 2000, auth_time: 1000,
    },
    expectedAuthUid: 'smartassist-controller-CTRL_001122aabbcc',
    expectedGeneration: 4,
    credentialStatus: 'active', operationStatus: 'pending',
    operationControllerId: 'CTRL_001122aabbcc',
    operationHouseId: 'owner-a', assignedHouseId: 'owner-a',
    nowSeconds: 1500, tokensValidAfterSeconds: 900,
  };
  assert.doesNotThrow(() => validateControllerIdentityClaims(valid));
  assert.throws(() => validateControllerIdentityClaims({ ...valid, uid: 'attacker' }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, credentialStatus: 'revoked' }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, expectedGeneration: 5 }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, operationControllerId: 'CTRL_another1234' }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, operationHouseId: 'house-b' }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, claims: { ...valid.claims, exp: 1499 } }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({ ...valid, claims: { ...valid.claims, auth_time: 899 } }), { code: 'permission-denied' });
  assert.doesNotThrow(() => validateControllerIdentityClaims({
    ...valid,
    credentialStatus: 'revoked', operationStatus: 'completed', assignedHouseId: null,
    claims: { ...valid.claims, auth_time: 899 },
  }));
});

test('credential generation stays stable for retries and advances after a completed unpair', () => {
  assert.equal(nextControllerCredentialGeneration(null, null), 1);
  assert.equal(nextControllerCredentialGeneration(3, 'active'), 3);
  assert.equal(nextControllerCredentialGeneration(3, 'provisioning'), 3);
  assert.equal(nextControllerCredentialGeneration(3, 'revoked'), 4);
});

test('legacy controller migration is owner-bound, one-use and preserves both House links', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  const migrationToken = token('z');
  const created = await createControllerIdentityMigrationSession({
    store, uid: 'owner-a', houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234',
    token: migrationToken, now, serverTimestamp: serverTime,
  });
  assert.equal(created.expiresAt.getTime() - now.getTime(), 5 * 60 * 1000);
  const session = store.read('controllerIdentityMigrationSessions', hashPairingToken(migrationToken));
  assert.equal(JSON.stringify(session).includes(migrationToken), false);
  await assert.rejects(consumeControllerIdentityMigrationSession({
    store, token: migrationToken, controllerId: 'CTRL_wrongid123', now, serverTimestamp: serverTime,
  }), { code: 'permission-denied' });
  const result = await consumeControllerIdentityMigrationSession({
    store, token: migrationToken, controllerId: 'CTRL_abcdefgh1234', now, serverTimestamp: serverTime,
  });
  assert.deepEqual(result, { houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234', ownerUid: 'owner-a' });
  assert.deepEqual(await consumeControllerIdentityMigrationSession({
    store, token: migrationToken, controllerId: 'CTRL_abcdefgh1234', now, serverTimestamp: serverTime,
  }), result);
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('migration requires the approved owner and rejects expired tokens', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  store.seed('users', 'member-a', {
    id: 'member-a', role: 'member', houseId: 'owner-a', isApproved: true,
  });
  await assert.rejects(createControllerIdentityMigrationSession({
    store, uid: 'member-a', houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234',
    token: token('x'), now, serverTimestamp: serverTime,
  }), { code: 'permission-denied' });
  const raw = token('w');
  await createControllerIdentityMigrationSession({
    store, uid: 'owner-a', houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234',
    token: raw, now, serverTimestamp: serverTime,
  });
  await assert.rejects(consumeControllerIdentityMigrationSession({
    store, token: raw, controllerId: 'CTRL_abcdefgh1234',
    now: new Date(now.getTime() + 5 * 60 * 1000), serverTimestamp: serverTime,
  }), { code: 'permission-denied' });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('pairing transaction failure leaves token and registry unchanged so the same claim can retry', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('y');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  store.failCommit = true;
  await assert.rejects(claim(store, rawToken, 'CTRL_abcdefgh1234'));
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234'), undefined);
  assert.equal(store.read('pairingSessions', hashPairingToken(rawToken)).consumedAt, null);
  await claim(store, rawToken, 'CTRL_abcdefgh1234');
  await claim(store, rawToken, 'CTRL_abcdefgh1234'); // lost response retry
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
});

test('pairing claim replay remains bound to the same controller, House and generation', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('r');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await claim(store, rawToken, 'CTRL_abcdefgh1234');

  assert.deepEqual(await claim(
    store, rawToken, 'CTRL_abcdefgh1234', new Date(now.getTime() + 6 * 60 * 1000),
  ), { houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234' });
  await assert.rejects(claim(
    store, rawToken, 'CTRL_ijklmnop5678', new Date(now.getTime() + 6 * 60 * 1000),
  ), { code: 'failed-precondition' });
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    ...store.read('controllers', 'CTRL_abcdefgh1234'),
    authCredentialGeneration: 2,
    authCredentialStatus: 'active',
  });
  await assert.rejects(claim(
    store, rawToken, 'CTRL_abcdefgh1234', new Date(now.getTime() + 6 * 60 * 1000),
  ), { code: 'failed-precondition' });
  await assert.rejects(claim(
    store, rawToken, 'CTRL_abcdefgh1234', new Date(now.getTime() + 10 * 60 * 1000 + 1),
  ), { code: 'failed-precondition' });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('device recovery secret is hash-only, controller/House/generation bound and expires', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('s');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await claim(store, rawToken, 'CTRL_abcdefgh1234');
  const recoveryDoc = store.read('controllerCredentialRecoverySessions', hashControllerRecoverySecret(recoverySecret('q')));
  assert.ok(recoveryDoc);
  assert.equal(JSON.stringify(recoveryDoc).includes(recoverySecret('q')), false);
  assert.deepEqual(await recoverMainControllerCredential({
    store, recoverySecret: recoverySecret('q'), controllerId: 'CTRL_abcdefgh1234', now,
  }), { houseId: 'owner-a', controllerId: 'CTRL_abcdefgh1234', credentialGeneration: 1 });
  await assert.rejects(recoverMainControllerCredential({
    store, recoverySecret: recoverySecret('q'), controllerId: 'CTRL_ijklmnop5678', now,
  }), { code: 'permission-denied' });
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    ...store.read('controllers', 'CTRL_abcdefgh1234'), activeHouseId: 'house-b',
  });
  await assert.rejects(recoverMainControllerCredential({
    store, recoverySecret: recoverySecret('q'), controllerId: 'CTRL_abcdefgh1234', now,
  }), { code: 'permission-denied' });
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    ...store.read('controllers', 'CTRL_abcdefgh1234'), activeHouseId: 'owner-a',
  });
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    ...store.read('controllers', 'CTRL_abcdefgh1234'),
    authCredentialGeneration: 2,
    authCredentialStatus: 'active',
  });
  await assert.rejects(recoverMainControllerCredential({
    store, recoverySecret: recoverySecret('q'), controllerId: 'CTRL_abcdefgh1234', now,
  }), { code: 'permission-denied' });
  await assert.rejects(recoverMainControllerCredential({
    store, recoverySecret: recoverySecret('q'), controllerId: 'CTRL_abcdefgh1234',
    now: new Date(now.getTime() + 10 * 60 * 1000),
  }), { code: 'permission-denied' });
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('invalid token cannot claim a controller and changes no registry records', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  await assert.rejects(claim(store, token('b'), 'CTRL_abcdefgh1234'), {
    code: 'permission-denied',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234'), undefined);
});

test('expired token is rejected without changing either registry side', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('c');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await assert.rejects(claim(store, rawToken, 'CTRL_abcdefgh1234', new Date(now.getTime() + 5 * 60 * 1000)), {
    code: 'permission-denied',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234'), undefined);
});

test('a consumed token cannot be reused', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('d');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await claim(store, rawToken, 'CTRL_abcdefgh1234');
  await assert.rejects(claim(store, rawToken, 'CTRL_ijklmnop5678'), {
    code: 'failed-precondition',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_ijklmnop5678'), undefined);
});

test('a House already paired cannot create another session or claim another controller', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  store.seed('houses', 'owner-a', { ...store.read('houses', 'owner-a'), mainControllerId: 'CTRL_abcdefgh1234' });
  await assert.rejects(issueSession(store, 'owner-a', 'owner-a', token('e')), {
    code: 'already-exists',
  });
  assert.equal(store.read('pairingSessions', hashPairingToken(token('e'))), undefined);
});

test('a House paired after session creation rejects the stale claim atomically', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('m');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  store.seed('houses', 'owner-a', {
    ...store.read('houses', 'owner-a'), mainControllerId: 'CTRL_existing1234',
  });
  await assert.rejects(claim(store, rawToken, 'CTRL_abcdefgh1234'), {
    code: 'already-exists',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_existing1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234'), undefined);
  assert.equal(store.read('pairingSessions', hashPairingToken(rawToken)).consumedAt, null);
});

test('a controller assigned to another House cannot be claimed', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    controllerId: 'CTRL_abcdefgh1234',
    activeHouseId: 'other-house',
    status: 'paired',
    pairedAt: 'historical-pair-time',
  });
  const rawToken = token('f');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await assert.rejects(claim(store, rawToken, 'CTRL_abcdefgh1234'), {
    code: 'already-exists',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'other-house');
  assert.equal(store.read('pairingSessions', hashPairingToken(rawToken)).consumedAt, null);
});

test('concurrent sessions cannot assign one controller to two Houses', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  seedOwner(store, 'owner-b');
  const tokenA = token('g');
  const tokenB = token('h');
  await issueSession(store, 'owner-a', 'owner-a', tokenA);
  await issueSession(store, 'owner-b', 'owner-b', tokenB);

  const outcomes = await Promise.allSettled([
    claim(store, tokenA, 'CTRL_shared1234'),
    claim(store, tokenB, 'CTRL_shared1234'),
  ]);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'fulfilled').length, 1);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'rejected').length, 1);
  const assignedHouse = store.read('controllers', 'CTRL_shared1234').activeHouseId;
  assert.equal(store.read('houses', assignedHouse).mainControllerId, 'CTRL_shared1234');
  const otherHouse = assignedHouse === 'owner-a' ? 'owner-b' : 'owner-a';
  assert.equal(store.read('houses', otherHouse).mainControllerId, null);
});

test('concurrent claim attempts for a House produce only one assignment', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const tokenA = token('i');
  const tokenB = token('j');
  await issueSession(store, 'owner-a', 'owner-a', tokenA);
  await issueSession(store, 'owner-a', 'owner-a', tokenB);

  const outcomes = await Promise.allSettled([
    claim(store, tokenA, 'CTRL_abcdefgh1234'),
    claim(store, tokenB, 'CTRL_ijklmnop5678'),
  ]);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'fulfilled').length, 1);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'rejected').length, 1);
  const assignedController = store.read('houses', 'owner-a').mainControllerId;
  assert.equal(store.read('controllers', assignedController).activeHouseId, 'owner-a');
  const unassignedController = assignedController === 'CTRL_abcdefgh1234'
    ? 'CTRL_ijklmnop5678'
    : 'CTRL_abcdefgh1234';
  assert.equal(store.read('controllers', unassignedController), undefined);
});

test('an approved member cannot create an owner pairing session', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  store.seed('users', 'member-a', {
    id: 'member-a', role: 'member', houseId: 'owner-a', isApproved: true,
  });
  await assert.rejects(issueSession(store, 'member-a', 'owner-a', token('k')), {
    code: 'permission-denied',
  });
  assert.equal(store.read('pairingSessions', hashPairingToken(token('k'))), undefined);
});

const opId = (char) => char.repeat(32);

async function requestUnpair(store, uid = 'owner-a', controllerId = 'CTRL_abcdefgh1234', id = opId('U'), at = now) {
  return requestMainControllerUnpair({
    store, uid, houseId: 'owner-a', controllerId,
    operationId: id,
    now: at,
    expiresAt: new Date(at.getTime() + 24 * 60 * 60 * 1000),
    serverTimestamp: serverTime,
  });
}

async function acknowledgePrepared(store, id = opId('U'), controllerId = 'CTRL_abcdefgh1234', at = now) {
  return acknowledgeMainControllerUnpairPrepared({
    store, operationId: id, controllerId, now: at, serverTimestamp: serverTime,
  });
}

async function acknowledgeCompleted(store, id = opId('U'), controllerId = 'CTRL_abcdefgh1234', at = now) {
  return acknowledgeMainControllerUnpairCompleted({
    store, operationId: id, controllerId, now: at, serverTimestamp: serverTime,
  });
}

function seedPairedOwner(store) {
  seedOwner(store, 'owner-a');
  store.seed('houses', 'owner-a', {
    ...store.read('houses', 'owner-a'), mainControllerId: 'CTRL_abcdefgh1234',
  });
  store.seed('controllers', 'CTRL_abcdefgh1234', {
    controllerId: 'CTRL_abcdefgh1234', activeHouseId: 'owner-a', status: 'paired',
    pairedAt: 'historical-pair-time', lastSeenAt: 'historical-last-seen',
  });
}

test('owner unpair stays reserved through prepare and only completes after device acknowledgement', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  const request = await requestUnpair(store);
  assert.equal(request.status, 'pending');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
  assert.equal((await acknowledgePrepared(store)).status, 'prepared');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal((await acknowledgeCompleted(store)).status, 'completed');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  const controller = store.read('controllers', 'CTRL_abcdefgh1234');
  assert.equal(controller.activeHouseId, null);
  assert.equal(controller.status, 'unpaired');
  assert.equal(controller.pendingUnpairOperationId, null);
  assert.equal(controller.pairedAt, 'historical-pair-time');
  assert.equal(controller.lastSeenAt, 'historical-last-seen');
  assert.equal(store.read('controllerUnpairOperations', opId('U')).status, 'completed');
});

test('unauthorized owner is denied and both registry documents remain consistent', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  store.seed('users', 'member-a', { id: 'member-a', role: 'member', houseId: 'owner-a', isApproved: true });
  await assert.rejects(requestUnpair(store, 'member-a'), { code: 'permission-denied' });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('wrong controller cannot create an unpair operation', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await assert.rejects(requestUnpair(store, 'owner-a', 'CTRL_wrongid123'), { code: 'failed-precondition' });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllerUnpairOperations', opId('U')), undefined);
});

test('repeated unpair requests return the same pending operation', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  const [first, second] = await Promise.all([
    requestUnpair(store, 'owner-a', 'CTRL_abcdefgh1234', opId('A')),
    requestUnpair(store, 'owner-a', 'CTRL_abcdefgh1234', opId('B')),
  ]);
  assert.equal(first.operationId, second.operationId);
  assert.equal(store.read('controllerUnpairOperations', opId('A')) != null, true);
  assert.equal(store.read('controllerUnpairOperations', opId('B')), undefined);
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
});

test('duplicate prepared and completed acknowledgements are idempotent', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  await acknowledgePrepared(store);
  await acknowledgePrepared(store);
  await acknowledgeCompleted(store);
  const duplicate = await acknowledgeCompleted(store);
  assert.equal(duplicate.status, 'completed');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, null);
});

test('completed acknowledgement retry after simulated reboot returns the same operation', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  await acknowledgePrepared(store);

  const first = await acknowledgeCompleted(store);
  const controllerAfterCommit = store.read('controllers', 'CTRL_abcdefgh1234');
  assert.equal(first.status, 'completed');
  assert.equal(controllerAfterCommit.activeHouseId, null);
  assert.equal(controllerAfterCommit.authCredentialStatus, 'revoked');

  // Simulate a reboot/lost HTTPS response: reconstruct the request using the
  // still-valid device ID token claims and retry the same durable operation.
  const replayClaims = {
    deviceType: 'main-controller',
    controllerId: 'CTRL_abcdefgh1234',
    credentialGeneration: 1,
    exp: 2000,
    auth_time: 1000,
  };
  const operation = store.read('controllerUnpairOperations', opId('U'));
  assert.doesNotThrow(() => validateControllerIdentityClaims({
    uid: 'smartassist-controller-CTRL_abcdefgh1234',
    controllerId: 'CTRL_abcdefgh1234',
    claims: replayClaims,
    expectedAuthUid: 'smartassist-controller-CTRL_abcdefgh1234',
    expectedGeneration: 1,
    credentialStatus: controllerAfterCommit.authCredentialStatus,
    operationStatus: operation.status,
    operationControllerId: operation.controllerId,
    operationHouseId: operation.houseId,
    assignedHouseId: controllerAfterCommit.activeHouseId,
    nowSeconds: 1500,
    tokensValidAfterSeconds: 1400,
  }));
  const retry = await acknowledgeCompleted(store);
  assert.equal(retry.operationId, first.operationId);
  assert.equal(retry.houseId, first.houseId);
  assert.equal(retry.controllerId, first.controllerId);
  assert.equal(retry.status, 'completed');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, null);
});

test('completed acknowledgement rejects a wrong identity or stale generation', () => {
  const claims = {
    deviceType: 'main-controller', controllerId: 'CTRL_abcdefgh1234',
    credentialGeneration: 1, exp: 2000, auth_time: 1000,
  };
  const baseline = {
    uid: 'smartassist-controller-CTRL_abcdefgh1234',
    controllerId: 'CTRL_abcdefgh1234',
    claims,
    expectedAuthUid: 'smartassist-controller-CTRL_abcdefgh1234',
    expectedGeneration: 1,
    credentialStatus: 'revoked', operationStatus: 'completed',
    operationControllerId: 'CTRL_abcdefgh1234',
    operationHouseId: 'owner-a', assignedHouseId: null,
    nowSeconds: 1500, tokensValidAfterSeconds: 1400,
  };
  assert.throws(() => validateControllerIdentityClaims({
    ...baseline,
    uid: 'smartassist-controller-CTRL_ijklmnop5678',
  }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({
    ...baseline,
    expectedGeneration: 2,
  }), { code: 'permission-denied' });
  assert.throws(() => validateControllerIdentityClaims({
    ...baseline,
    operationControllerId: 'CTRL_ijklmnop5678',
  }), { code: 'permission-denied' });
});

test('a prior generation cannot acknowledge an old operation after the controller is paired again', () => {
  const claims = {
    deviceType: 'main-controller', controllerId: 'CTRL_abcdefgh1234',
    credentialGeneration: 1, exp: 2000, auth_time: 1000,
  };
  assert.throws(() => validateControllerIdentityClaims({
    uid: 'smartassist-controller-CTRL_abcdefgh1234',
    controllerId: 'CTRL_abcdefgh1234',
    claims,
    expectedAuthUid: 'smartassist-controller-CTRL_abcdefgh1234',
    expectedGeneration: 2,
    credentialStatus: 'active',
    operationStatus: 'completed',
    operationControllerId: 'CTRL_abcdefgh1234',
    operationHouseId: 'old-house',
    assignedHouseId: 'new-house',
    nowSeconds: 1500,
    tokensValidAfterSeconds: 1400,
  }), { code: 'permission-denied' });
});

test('a lost request response can be recovered after completion without creating a new operation', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  const first = await requestUnpair(store);
  await acknowledgePrepared(store);
  await acknowledgeCompleted(store);
  const retried = await requestUnpair(store, 'owner-a', 'CTRL_abcdefgh1234', opId('R'));
  assert.equal(retried.operationId, first.operationId);
  assert.equal(retried.status, 'completed');
  assert.equal(store.read('controllerUnpairOperations', opId('R')), undefined);
});

test('acknowledgement from a different controller cannot advance the operation', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  await assert.rejects(acknowledgePrepared(store, opId('U'), 'CTRL_ijklmnop5678'), {
    code: 'not-found',
  });
  assert.equal(store.read('controllerUnpairOperations', opId('U')).status, 'pending');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('offline controller leaves operation pending and assignment reserved for retry', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  assert.equal(await recordUnpairDeliveryAttempt({
    store,
    operationId: opId('U'),
    nextDeliveryAt: new Date(now.getTime() + 60_000),
    serverTimestamp: serverTime,
  }), 'pending');
  assert.equal(store.read('controllerUnpairOperations', opId('U')).status, 'pending');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('expired prepare operation fails without releasing either registry side', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  const expiredAt = new Date(now.getTime() + 24 * 60 * 60 * 1000);
  assert.equal(await expireMainControllerUnpair({
    store, operationId: opId('U'), now: expiredAt, serverTimestamp: serverTime,
  }), true);
  assert.equal(store.read('controllerUnpairOperations', opId('U')).status, 'failed');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
  await assert.rejects(acknowledgePrepared(store, opId('U'), 'CTRL_abcdefgh1234', expiredAt), {
    code: 'failed-precondition',
  });
});

test('transaction commit failure leaves the operation and both registry documents unchanged', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  store.failCommit = true;
  await assert.rejects(requestUnpair(store), /Injected transaction commit failure/);
  assert.equal(store.read('controllerUnpairOperations', opId('U')), undefined);
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('houses', 'owner-a').pendingUnpairOperationId, undefined);
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('completion transaction failure cannot clear only one registry side', async () => {
  const store = new MemoryPairingStore();
  seedPairedOwner(store);
  await requestUnpair(store);
  await acknowledgePrepared(store);
  store.failCommit = true;
  await assert.rejects(acknowledgeCompleted(store), /Injected transaction commit failure/);
  assert.equal(store.read('controllerUnpairOperations', opId('U')).status, 'prepared');
  assert.equal(store.read('houses', 'owner-a').mainControllerId, 'CTRL_abcdefgh1234');
  assert.equal(store.read('controllers', 'CTRL_abcdefgh1234').activeHouseId, 'owner-a');
});

test('malformed controller IDs are rejected before registry writes', async () => {
  const store = new MemoryPairingStore();
  seedOwner(store, 'owner-a');
  const rawToken = token('l');
  await issueSession(store, 'owner-a', 'owner-a', rawToken);
  await assert.rejects(claim(store, rawToken, 'aa:bb:cc:dd:ee:ff'), {
    code: 'invalid-argument',
  });
  assert.equal(store.read('houses', 'owner-a').mainControllerId, null);
});
