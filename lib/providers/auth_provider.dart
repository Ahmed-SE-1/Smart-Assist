import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/user.dart';
import '../services/local_storage_service.dart';
import './automation_provider.dart';
import './smart_home_provider.dart';
import 'service_providers.dart';
import 'user_provider.dart';

class AuthState {
  final bool isAuthenticated;
  final String? error;
  final bool isLoading;
  final bool isInitializing;
  final bool isPendingApproval;

  const AuthState({
    this.isAuthenticated = false,
    this.error,
    this.isLoading = false,
    this.isInitializing = true,
    this.isPendingApproval = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? error,
    bool? isLoading,
    bool? isInitializing,
    bool? isPendingApproval,
    bool clearError = false,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
      isInitializing: isInitializing ?? this.isInitializing,
      isPendingApproval: isPendingApproval ?? this.isPendingApproval,
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  final LocalStorageService _storage = LocalStorageService();
  final firebase.FirebaseAuth _auth = firebase.FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  AuthState build() {
    Future.microtask(_checkLoginStatus);
    return const AuthState();
  }

  Future<void> _checkLoginStatus() async {
    try {
      final firebaseUser = _auth.currentUser;
      final isLogged = firebaseUser != null;

      if (isLogged) {
        final doc =
            await _firestore.collection('users').doc(firebaseUser.uid).get();
        if (doc.exists) {
          final user = User.fromMap(doc.data()!);
          ref.read(userProvider.notifier).setUser(user);
          unawaited(_ensureOwnerIndexes(user));
          state = state.copyWith(isPendingApproval: !user.isApproved);
        } else {
          // Invalid user state
          await logout();
        }
      }

      state = state.copyWith(isAuthenticated: isLogged, isInitializing: false);
    } catch (e) {
      state = state.copyWith(isInitializing: false, error: e.toString());
    }
  }

  // ════════════════════════════════════════════════
  // EMAIL / PASSWORD AUTHENTICATION
  // ════════════════════════════════════════════════

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final doc =
          await _firestore
              .collection('users')
              .doc(userCredential.user!.uid)
              .get();
      if (doc.exists) {
        final user = User.fromMap(doc.data()!);
        ref.read(userProvider.notifier).setUser(user);
        unawaited(_ensureOwnerIndexes(user));
        state = state.copyWith(isPendingApproval: !user.isApproved);
      } else {
        throw "User role data not found in database.";
      }

      state = state.copyWith(isAuthenticated: true, isLoading: false);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? 'Login failed',
      );
      return false;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> signup(
    String name,
    String email,
    String password,
    UserRole role, {
    String? joinCode,
    String? houseName,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    firebase.User?
    pendingUser; // agar profile ban na paye to ye auth account delete hoga
    try {
      _validateRegistrationInput(
        role,
        joinCode: joinCode,
        houseName: houseName,
      );

      // 2. Auth account
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final createdUser = userCredential.user;
      if (createdUser == null) {
        throw 'User account could not be created. Please try again.';
      }
      pendingUser = createdUser;
      await createdUser.updateDisplayName(name);

      // Identity and House membership are resolved by authenticated Functions.
      final registration = ref.read(registrationServiceProvider);
      final newUser =
          role == UserRole.owner
              ? await registration.registerOwner(
                name: name,
                houseName: houseName!.trim(),
              )
              : await registration.registerMember(
                name: name,
                joinCode: joinCode!.trim(),
              );
      pendingUser = null; // profile ban gayi, ab delete nahi karna

      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !newUser.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      // Adhoora auth account saaf karein taake user dobara try kar sake
      try {
        await pendingUser?.delete();
      } catch (_) {}
      state = state.copyWith(isLoading: false, error: _friendlyError(e));
      return false;
    }
  }

  // ════════════════════════════════════════════════
  // GOOGLE AUTHENTICATION
  // ════════════════════════════════════════════════

  /// [LOGIN ONLY] Ye method sirf Login Screen se call hoga.
  /// Agar user registered nahi hai, toh ye reject kar dega.
  Future<bool> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();
      final googleAuth = googleUser.authentication;
      final authorizedUser = await googleUser.authorizationClient
          .authorizeScopes(['email', 'profile']);

      final credential = firebase.GoogleAuthProvider.credential(
        accessToken: authorizedUser.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      final uid = userCredential.user!.uid;

      // LOGIN CHECK: Pura user data fetch karo
      final doc = await _firestore.collection('users').doc(uid).get();
      if (!doc.exists) {
        // User NOT Registered
        await _auth.signOut();
        await _googleSignIn.signOut();
        throw "User not Registered. Please sign up to register your House or Join Code first.";
      }

      final user = User.fromMap(doc.data()!);
      ref.read(userProvider.notifier).setUser(user);
      unawaited(_ensureOwnerIndexes(user));

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !user.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      // Remove generic Firebase strings for a cleaner UI error
      final errorMsg = _friendlyError(e);
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  /// [SIGNUP ONLY] Ye method sirf Signup Screen se call hoga.
  /// UI mein user pehle House Name ya Join code likhega, phir Google button press karega.
  Future<bool> signUpWithGoogle(
    UserRole role, {
    String? houseName,
    String? joinCode,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Validation (Google popup open hone se pehle, bina sign in ke)
      _validateRegistrationInput(
        role,
        joinCode: joinCode,
        houseName: houseName,
      );

      // 2. Google Authentication Step
      await _googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();
      final googleAuth = googleUser.authentication;
      final authorizedUser = await googleUser.authorizationClient
          .authorizeScopes(['email', 'profile']);

      final credential = firebase.GoogleAuthProvider.credential(
        accessToken: authorizedUser.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);
      final uid = userCredential.user!.uid;

      // 3. Check if already completely registered
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        throw "This Google account is already registered. Please login instead.";
      }

      // 4. Create new User Profile in Database
      final registration = ref.read(registrationServiceProvider);
      final displayName = userCredential.user!.displayName ?? 'Google User';
      final newUser =
          role == UserRole.owner
              ? await registration.registerOwner(
                name: displayName,
                houseName: houseName!.trim(),
              )
              : await registration.registerMember(
                name: displayName,
                joinCode: joinCode!.trim(),
              );

      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !newUser.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      // Agar error ata hai toh Google auth ko wapis logout kardo
      await _auth.signOut();
      await _googleSignIn.signOut();

      final errorMsg = _friendlyError(e);
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  // ════════════════════════════════════════════════
  // HELPERS
  // ════════════════════════════════════════════════

  void _validateRegistrationInput(
    UserRole role, {
    String? joinCode,
    String? houseName,
  }) {
    if (role == UserRole.member &&
        (joinCode == null || joinCode.trim().isEmpty)) {
      throw 'Please enter a Join Code provided by the House Owner.';
    }
    if (role == UserRole.owner &&
        (houseName == null || houseName.trim().isEmpty)) {
      throw 'Please provide a House Name or Number.';
    }
  }

  String _friendlyError(Object error) {
    if (error is FirebaseFunctionsException) {
      return error.message ??
          'Registration could not be completed. Please try again.';
    }
    if (error is firebase.FirebaseAuthException) {
      return error.message ?? 'Authentication failed. Please try again.';
    }
    if (error is String) return error;
    return 'Registration could not be completed. Please try again.';
  }

  Future<void> _ensureOwnerIndexes(User user) async {
    if (user.role != UserRole.owner) return;
    try {
      final joinCode =
          await ref.read(registrationServiceProvider).ensureOwnerIndexes();
      if (joinCode == null || joinCode == user.joinCode) return;
      if (_auth.currentUser?.uid != user.id ||
          ref.read(userProvider)?.id != user.id) {
        return;
      }
      ref.read(userProvider.notifier).setUser(user.copyWith(joinCode: joinCode));
    } catch (_) {
      // Legacy index repair must not hold up authentication or navigation.
    }
  }

  /// Re-reads approval so a member can continue after an owner approves them.
  Future<bool> refreshApprovalStatus() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return false;
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final data = doc.data();
      if (!doc.exists || data == null || data['id'] != uid) return false;
      final user = User.fromMap(data);
      ref.read(userProvider.notifier).setUser(user);
      state = state.copyWith(isPendingApproval: !user.isApproved);
      return user.isApproved;
    } catch (error) {
      state = state.copyWith(error: _friendlyError(error));
      return false;
    }
  }

  Future<bool> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  Future<void> logout() async {
    await _auth.signOut();
    await _googleSignIn.signOut();
    ref.read(userProvider.notifier).clearUser();
    ref.invalidate(roomsProvider);
    ref.invalidate(devicesProvider);
    ref.invalidate(activityLogProvider);
    ref.invalidate(automationProvider);
    state = state.copyWith(isAuthenticated: false, isPendingApproval: false);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
