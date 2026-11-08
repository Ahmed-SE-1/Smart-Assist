import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/models/controller_registry_entry.dart';
import 'package:smart_home/models/house.dart';
import 'package:smart_home/models/node_registry_entry.dart';
import 'package:smart_home/services/house_service.dart';

void main() {
  final now = DateTime.utc(2026, 11, 3, 12, 30);

  test('House serializes Firestore timestamps and null controller assignment', () {
    final house = House(
      houseId: 'owner-uid',
      ownerUid: 'owner-uid',
      name: 'Home',
      mainControllerId: null,
      createdAt: now,
      updatedAt: now,
    );

    final map = house.toMap();
    expect(map['houseId'], 'owner-uid');
    expect(map['mainControllerId'], isNull);
    expect(map['createdAt'], isA<Timestamp>());
    expect(House.fromMap(map).createdAt, now);
    expect(House.fromMap(map).mainControllerId, isNull);
  });

  test('Controller registry round-trips timestamps and nullable fields', () {
    final controller = ControllerRegistryEntry(
      controllerId: 'physical-controller-id',
      activeHouseId: null,
      status: 'offline',
      pairedAt: null,
      lastSeenAt: now,
    );

    final map = controller.toMap();
    expect(map['controllerId'], 'physical-controller-id');
    expect(map['activeHouseId'], isNull);
    expect(map['pairedAt'], isNull);
    expect(map['lastSeenAt'], isA<Timestamp>());
    final decoded = ControllerRegistryEntry.fromMap(map);
    expect(decoded.activeHouseId, isNull);
    expect(decoded.pairedAt, isNull);
    expect(decoded.lastSeenAt, now);
  });

  test('Node registry round-trips nullable pairing fields', () {
    final node = NodeRegistryEntry(
      nodeId: 'physical-node-id',
      controllerId: null,
      houseId: null,
      roomId: null,
      status: 'unpaired',
      pairedAt: null,
      lastSeenAt: null,
    );

    final map = node.toMap();
    expect(map['nodeId'], 'physical-node-id');
    expect(map['controllerId'], isNull);
    expect(map['houseId'], isNull);
    expect(map['roomId'], isNull);
    expect(map['pairedAt'], isNull);
    final decoded = NodeRegistryEntry.fromMap(map);
    expect(decoded.controllerId, isNull);
    expect(decoded.houseId, isNull);
    expect(decoded.roomId, isNull);
    expect(decoded.lastSeenAt, isNull);
  });

  test('Legacy migration preserves the owner UID as House ID', () {
    final plan = LegacyHouseMigrationPlanner.plan(
      profiles: [
        const LegacyHouseOwnerProfile(
          documentId: 'owner-uid',
          data: {
            'id': 'owner-uid',
            'houseId': 'owner-uid',
            'houseName': 'Home',
            'role': 'owner',
          },
        ),
      ],
      existingHouseIds: const {},
      timestamp: now,
    );

    expect(plan.housesToCreate, hasLength(1));
    expect(plan.housesToCreate.single.houseId, 'owner-uid');
    expect(plan.housesToCreate.single.ownerUid, 'owner-uid');
    expect(plan.housesToCreate.single.mainControllerId, isNull);
    expect(plan.issues, isEmpty);
  });

  test('Existing House document is skipped and never planned for overwrite', () {
    final plan = LegacyHouseMigrationPlanner.plan(
      profiles: [
        const LegacyHouseOwnerProfile(
          documentId: 'owner-uid',
          data: {
            'id': 'owner-uid',
            'houseId': 'owner-uid',
            'houseName': 'Home',
            'role': 'owner',
          },
        ),
      ],
      existingHouseIds: const {'owner-uid'},
      existingHouses: const {
        'owner-uid': {
          'houseId': 'owner-uid',
          'ownerUid': 'owner-uid',
          'name': 'Home',
          'mainControllerId': null,
        },
      },
      timestamp: now,
    );

    expect(plan.housesToCreate, isEmpty);
    expect(plan.existingHouseIds, ['owner-uid']);
    expect(plan.issues, isEmpty);
    expect(plan.conflicts, isEmpty);
  });

  test('Conflicting existing House document is reported and never overwritten', () {
    final plan = LegacyHouseMigrationPlanner.plan(
      profiles: [
        const LegacyHouseOwnerProfile(
          documentId: 'owner-uid',
          data: {
            'id': 'owner-uid',
            'houseId': 'owner-uid',
            'houseName': 'Home',
            'role': 'owner',
          },
        ),
      ],
      existingHouseIds: const {'owner-uid'},
      existingHouses: const {
        'owner-uid': {
          'houseId': 'owner-uid',
          'ownerUid': 'someone-else',
          'name': 'Other House',
          'mainControllerId': null,
        },
      },
      timestamp: now,
    );

    expect(plan.housesToCreate, isEmpty);
    expect(plan.existingHouseIds, isEmpty);
    expect(plan.conflicts, hasLength(1));
    expect(plan.conflicts.single.profileId, 'owner-uid');
  });

  test('Duplicate and inconsistent legacy owner profiles are reported', () {
    const valid = LegacyHouseOwnerProfile(
      documentId: 'owner-a',
      data: {
        'id': 'owner-a',
        'houseId': 'owner-a',
        'houseName': 'Same Home',
        'role': 'owner',
      },
    );
    const duplicateName = LegacyHouseOwnerProfile(
      documentId: 'owner-b',
      data: {
        'id': 'owner-b',
        'houseId': 'owner-b',
        'houseName': ' same home ',
        'role': 'owner',
      },
    );
    const inconsistent = LegacyHouseOwnerProfile(
      documentId: 'owner-c',
      data: {
        'id': 'owner-c',
        'houseId': 'another-house',
        'houseName': 'Unknown',
        'role': 'owner',
      },
    );

    final plan = LegacyHouseMigrationPlanner.plan(
      profiles: [valid, duplicateName, inconsistent],
      existingHouseIds: const {},
      timestamp: now,
    );

    expect(plan.housesToCreate, isEmpty);
    expect(plan.issues, hasLength(3));
    expect(plan.issues.map((issue) => issue.profileId), containsAll([
      'owner-a',
      'owner-b',
      'owner-c',
    ]));
  });

  test('Duplicate owner rows are reported and excluded from migration', () {
    const owner = LegacyHouseOwnerProfile(
      documentId: 'owner-a',
      data: {
        'id': 'owner-a',
        'houseId': 'owner-a',
        'houseName': 'Home',
        'role': 'owner',
      },
    );

    final plan = LegacyHouseMigrationPlanner.plan(
      profiles: [owner, owner],
      existingHouseIds: const {},
      timestamp: now,
    );

    expect(plan.housesToCreate, isEmpty);
    expect(plan.issues, hasLength(1));
    expect(plan.issues.single.profileId, 'owner-a');
  });
}
