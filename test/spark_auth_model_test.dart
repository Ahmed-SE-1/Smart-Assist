import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/models/house.dart';
import 'package:smart_home/models/user.dart';

void main() {
  group('Spark Authentication Data Structures', () {
    test('Owner user toMap satisfies security rules constraints', () {
      final owner = User(
        id: 'user_123',
        name: 'House Owner',
        email: 'owner@example.com',
        role: UserRole.owner,
        houseId: 'user_123',
        houseName: 'Green Villa',
        isApproved: true,
        joinCode: '654321',
      );

      final map = owner.toMap();

      // Rule: request.resource.data.keys().hasOnly(['id', 'name', 'email', 'avatarUrl', 'role', 'houseId', 'houseName', 'isApproved', 'joinCode', 'assignedRoomIds'])
      const allowedKeys = {
        'id',
        'name',
        'email',
        'avatarUrl',
        'role',
        'houseId',
        'houseName',
        'isApproved',
        'joinCode',
        'assignedRoomIds',
      };
      expect(map.keys.toSet().difference(allowedKeys), isEmpty);

      // Rule: validOwnerUserCreate assertions
      expect(map['id'], 'user_123');
      expect(map['role'], 'owner');
      expect(map['houseId'], 'user_123');
      expect(map['isApproved'], isTrue);
      expect(map['houseName'], 'Green Villa');
      expect(RegExp(r'^[0-9]{6}$').hasMatch(map['joinCode']), isTrue);
    });

    test('Member user toMap satisfies security rules constraints', () {
      final member = User(
        id: 'member_456',
        name: 'Family Member',
        email: 'member@example.com',
        role: UserRole.member,
        houseId: 'user_123',
        houseName: 'Green Villa',
        isApproved: false,
        joinCode: '654321',
      );

      final map = member.toMap();

      expect(map['id'], 'member_456');
      expect(map['role'], 'member');
      expect(map['houseId'], 'user_123');
      expect(map['isApproved'], isFalse);
      expect(RegExp(r'^[0-9]{6}$').hasMatch(map['joinCode']), isTrue);
    });

    test('Owner House document structure matches registry schema', () {
      final house = House(
        houseId: 'user_123',
        ownerUid: 'user_123',
        name: 'Green Villa',
        mainControllerId: null,
      );

      final map = house.toMap();
      const allowedHouseKeys = {
        'houseId',
        'ownerUid',
        'name',
        'mainControllerId',
        'createdAt',
        'updatedAt',
      };
      expect(map.keys.toSet().difference(allowedHouseKeys), isEmpty);
      expect(map['houseId'], 'user_123');
      expect(map['ownerUid'], 'user_123');
      expect(map['mainControllerId'], isNull);
    });
  });
}

