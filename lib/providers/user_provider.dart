import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user.dart';
import '../services/local_storage_service.dart';

class UserNotifier extends Notifier<User?> {
  final LocalStorageService _storage = LocalStorageService();

  @override
  User? build() {
    return null;
  }

  Future<void> loadUser() async {
    final user = await _storage.getUser();
    state = user;
  }
  
  void setUser(User user) {
      state = user;
      _storage.saveUser(user);
  }

  Future<void> updateUser({
    String? name,
    String? email,
    String? avatarUrl,
  }) async {
    if (state != null) {
      final updatedUser = state!.copyWith(
        name: name,
        email: email,
        avatarUrl: avatarUrl,
      );
      state = updatedUser;
      await _storage.saveUser(updatedUser);
    }
  }

  Future<void> clearUser() async {
    state = null;
    await _storage.clearUser();
  }
}

final userProvider = NotifierProvider<UserNotifier, User?>(UserNotifier.new);
