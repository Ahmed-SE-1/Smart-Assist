import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
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

      final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
      if (uid != null && uid == updatedUser.id) {
        final updateData = <String, dynamic>{};
        if (name != null) updateData['name'] = name;
        if (avatarUrl != null) updateData['avatarUrl'] = avatarUrl;
        if (updateData.isNotEmpty) {
          try {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .update(updateData);
          } catch (_) {}
        }
      }
    }
  }

  Future<void> clearUser() async {
    state = null;
    await _storage.clearUser();
  }
}

final userProvider = NotifierProvider<UserNotifier, User?>(UserNotifier.new);
