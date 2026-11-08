const test = require('node:test');
const assert = require('node:assert/strict');
const {
  assertProfileDoesNotExist,
  buildHouseRegistryEntry,
  buildMemberProfile,
  buildOwnerProfile,
  houseNameIndexKey,
  houseRegistryConflict,
  normalizeHouseName,
} = require('../lib/registration_domain.js');

const identity = {
  uid: 'authenticated-member-uid',
  email: 'member@example.com',
  avatarUrl: null,
};

test('invalid join-code records are rejected without producing a profile', () => {
  assert.throws(() => buildMemberProfile({
    identity,
    displayName: 'Member',
    joinCodeDocument: null,
    ownerProfile: null,
  }), { reason: 'invalid-join-code' });
});

test('member profile derives House and role only from trusted records', () => {
  const member = buildMemberProfile({
    identity,
    displayName: ' Member ',
    joinCodeDocument: { ownerId: 'trusted-owner-uid', houseName: 'Trusted House' },
    ownerProfile: {
      id: 'trusted-owner-uid',
      role: 'owner',
      houseId: 'trusted-owner-uid',
      houseName: 'Trusted House',
      isApproved: true,
    },
  });

  assert.equal(member.id, identity.uid);
  assert.equal(member.role, 'member');
  assert.equal(member.houseId, 'trusted-owner-uid');
  assert.equal(member.houseName, 'Trusted House');
  assert.equal(member.isApproved, false);
});

test('duplicate profile registration is rejected', () => {
  assert.throws(() => assertProfileDoesNotExist(true), { reason: 'duplicate-profile' });
  assert.doesNotThrow(() => assertProfileDoesNotExist(false));
});

test('owner registration derives House identity from authenticated UID', () => {
  const owner = buildOwnerProfile({
    identity: { ...identity, uid: 'owner-uid' },
    displayName: 'Owner',
    houseName: 'Home',
    joinCode: '123456',
  });
  assert.equal(owner.id, 'owner-uid');
  assert.equal(owner.houseId, 'owner-uid');
  assert.equal(owner.role, 'owner');
  assert.equal(owner.isApproved, true);
});

test('owner registration House registry entry uses the authenticated UID and starts unpaired', () => {
  const uid = 'owner-uid';
  const house = buildHouseRegistryEntry(uid, uid, 'Home');
  assert.deepEqual(house, {
    houseId: uid,
    ownerUid: uid,
    name: 'Home',
    mainControllerId: null,
  });
});

test('matching House registry entry is accepted without requiring replacement', () => {
  const existing = {
    houseId: 'owner-uid',
    ownerUid: 'owner-uid',
    name: 'Home',
    mainControllerId: 'controller-1',
    createdAt: 'existing-created-at',
    updatedAt: 'existing-updated-at',
  };
  assert.equal(houseRegistryConflict(
    'owner-uid',
    { ownerUid: 'owner-uid', name: 'Home' },
    existing,
  ), null);
  assert.equal(existing.mainControllerId, 'controller-1');
  assert.equal(existing.createdAt, 'existing-created-at');
});

test('House registry entry with mismatched owner or ID is rejected as a conflict', () => {
  assert.notEqual(houseRegistryConflict(
    'owner-uid',
    { ownerUid: 'owner-uid', name: 'Home' },
    { houseId: 'different-id', ownerUid: 'owner-uid', name: 'Home' },
  ), null);
  assert.notEqual(houseRegistryConflict(
    'owner-uid',
    { ownerUid: 'owner-uid', name: 'Home' },
    { houseId: 'owner-uid', ownerUid: 'someone-else', name: 'Home' },
  ), null);
});

test('House-name uniqueness uses normalized encoded key', () => {
  assert.equal(normalizeHouseName('  My Home  '), 'My Home');
  assert.equal(houseNameIndexKey('My Home'), 'my%20home');
});

test('migration identifies a mismatched existing House as a conflict', () => {
  assert.notEqual(houseRegistryConflict(
    'owner-uid',
    { ownerUid: 'owner-uid', name: 'Expected' },
    { houseId: 'owner-uid', ownerUid: 'other', name: 'Unexpected', mainControllerId: null },
  ), null);
  assert.equal(houseRegistryConflict(
    'owner-uid',
    { ownerUid: 'owner-uid', name: 'Expected' },
    { houseId: 'owner-uid', ownerUid: 'owner-uid', name: 'Expected', mainControllerId: null },
  ), null);
});
