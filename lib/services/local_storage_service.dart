import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

/// A robust wrapper around `SharedPreferences` for local data persistence.
/// Handles caching user data and authentication state.
class LocalStorageService {
  // Constant keys used to read/write from the device's persistent storage
  static const String _userKey = 'user_data';

  /// Saves the current user's profile to local storage.
  Future<void> saveUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, json.encode(user.toMap()));
  }

  /// Fetches the currently active user profile from local storage.
  Future<User?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(_userKey);
    if (userStr != null) {
      return User.fromMap(json.decode(userStr));
    }
    return null;
  }

  /// Wipes the current user data from memory (called during Logout).
  Future<void> clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }
}