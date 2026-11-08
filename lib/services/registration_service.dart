import 'package:cloud_functions/cloud_functions.dart';

import '../models/user.dart';

abstract interface class CallableInvoker {
  Future<Map<String, dynamic>> call(
    String functionName,
    Map<String, dynamic> payload,
  );
}

class FirebaseCallableInvoker implements CallableInvoker {
  FirebaseCallableInvoker({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  @override
  Future<Map<String, dynamic>> call(
    String functionName,
    Map<String, dynamic> payload,
  ) async {
    final response = await _functions
        .httpsCallable(functionName)
        .call<Map<String, dynamic>>(payload);
    return response.data;
  }
}

/// Sends only registration input; House identity and privileges come back
/// from trusted Functions responses.
class HouseRegistrationService {
  const HouseRegistrationService(this._callable);

  final CallableInvoker _callable;

  Future<User> registerOwner({
    required String name,
    required String houseName,
  }) async {
    final response = await _callable.call('registerOwner', {
      'name': name,
      'houseName': houseName,
    });
    return _userFromResponse(response);
  }

  Future<User> registerMember({
    required String name,
    required String joinCode,
  }) async {
    final response = await _callable.call('registerMember', {
      'name': name,
      'joinCode': joinCode,
    });
    return _userFromResponse(response);
  }

  Future<String?> ensureOwnerIndexes() async {
    final response = await _callable.call('ensureOwnerIndexes', const {});
    final code = response['joinCode'];
    return code is String && code.isNotEmpty ? code : null;
  }

  User _userFromResponse(Map<String, dynamic> response) {
    final user = response['user'];
    if (user is! Map) {
      throw const FormatException('Registration response is invalid.');
    }
    return User.fromMap(Map<String, dynamic>.from(user));
  }
}
