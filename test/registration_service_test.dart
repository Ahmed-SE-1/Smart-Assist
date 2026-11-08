import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/models/user.dart';
import 'package:smart_home/services/registration_service.dart';

class _FakeCallable implements CallableInvoker {
  final calls = <({String name, Map<String, dynamic> payload})>[];
  Map<String, dynamic> response = {};

  @override
  Future<Map<String, dynamic>> call(
    String functionName,
    Map<String, dynamic> payload,
  ) async {
    calls.add((name: functionName, payload: payload));
    return response;
  }
}

void main() {
  test('Owner registration sends only display and House name input', () async {
    final callable = _FakeCallable()
      ..response = {
        'user': {
          'id': 'auth-uid',
          'name': 'Owner',
          'email': 'owner@example.com',
          'role': 'owner',
          'houseId': 'auth-uid',
          'houseName': 'My House',
          'isApproved': true,
          'joinCode': '123456',
        },
      };

    final user = await HouseRegistrationService(callable).registerOwner(
      name: 'Owner',
      houseName: 'My House',
    );

    expect(callable.calls.single.name, 'registerOwner');
    expect(callable.calls.single.payload, {
      'name': 'Owner',
      'houseName': 'My House',
    });
    expect(user.id, 'auth-uid');
    expect(user.role, UserRole.owner);
    expect(user.houseId, 'auth-uid');
    expect(user.isApproved, isTrue);
  });

  test('Member registration sends no client-selected House or privileges', () async {
    final callable = _FakeCallable()
      ..response = {
        'user': {
          'id': 'member-uid',
          'name': 'Member',
          'email': 'member@example.com',
          'role': 'member',
          'houseId': 'trusted-owner-uid',
          'houseName': 'Trusted House',
          'isApproved': false,
          'joinCode': null,
        },
      };

    final user = await HouseRegistrationService(callable).registerMember(
      name: 'Member',
      joinCode: '123456',
    );

    expect(callable.calls.single.name, 'registerMember');
    expect(callable.calls.single.payload, {
      'name': 'Member',
      'joinCode': '123456',
    });
    expect(user.role, UserRole.member);
    expect(user.houseId, 'trusted-owner-uid');
    expect(user.houseName, 'Trusted House');
    expect(user.isApproved, isFalse);
  });
}
