import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/user.dart';
import '../services/local_storage_service.dart';
import './automation_provider.dart';
import './smart_home_provider.dart';
import 'user_provider.dart';

class AuthState {
  final bool isAuthenticated;
  final String? error;
  final bool isLoading;
  final bool isInitializing;

  const AuthState({
    this.isAuthenticated = false,
    this.error,
    this.isLoading = false,
    this.isInitializing = true,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? error,
    bool? isLoading,
    bool? isInitializing,
    bool clearError = false,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
      isInitializing: isInitializing ?? this.isInitializing,
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
      await Future.delayed(const Duration(seconds: 2));

      final firebaseUser = _auth.currentUser;
      final isLogged = firebaseUser != null;

      if (isLogged) {
        final doc = await _firestore.collection('users').doc(firebaseUser.uid).get();
        if (doc.exists) {
          final user = User.fromMap(doc.data()!);
          ref.read(userProvider.notifier).setUser(user);
          await _ensureOwnerIndexes(user); // purane owners ke liye self-heal
        } else {
          // Invalid user state
          await logout();
        }
      }

      state = state.copyWith(
        isAuthenticated: isLogged,
        isInitializing: false,
      );
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
      final userCredential = await _auth.signInWithEmailAndPassword(email: email, password: password);

      final doc = await _firestore.collection('users').doc(userCredential.user!.uid).get();
      if (doc.exists) {
        final user = User.fromMap(doc.data()!);
        ref.read(userProvider.notifier).setUser(user);
        await _ensureOwnerIndexes(user);
      } else {
        throw "User role data not found in database.";
      }

      state = state.copyWith(isAuthenticated: true, isLoading: false);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message ?? 'Login failed');
      return false;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> signup(String name, String email, String password, UserRole role,
      {String? joinCode, String? houseName}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    firebase.User? pendingUser; // agar profile ban na paye to ye auth account delete hoga
    try {
      // 1. Validation (bina sign in ke chalta hai: sirf single-doc get use hota hai)
      final house = await _validateHouse(role, joinCode: joinCode, houseName: houseName);

      // 2. Auth account
      final userCredential = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      pendingUser = userCredential.user;
      final uid = pendingUser!.uid;
      await pendingUser.updateDisplayName(name);

      // 3. Firestore profile (+ owner ke liye joinCodes / houseNames)
      final newUser = await _createProfile(
        uid: uid,
        name: name,
        email: email,
        role: role,
        houseId: house.houseId,
        houseName: house.houseName,
      );
      pendingUser = null; // profile ban gayi, ab delete nahi karna

      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(isAuthenticated: true, isLoading: false);
      return true;
    } catch (e) {
      // Adhoora auth account saaf karein taake user dobara try kar sake
      try {
        await pendingUser?.delete();
      } catch (_) {}
      state = state.copyWith(isLoading: false, error: e.toString());
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
      final authorizedUser = await googleUser.authorizationClient.authorizeScopes(['email', 'profile']);

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
      await _ensureOwnerIndexes(user);

      state = state.copyWith(isAuthenticated: true, isLoading: false);
      return true;
    } catch (e) {
      // Remove generic Firebase strings for a cleaner UI error
      final errorMsg = e.toString().replaceFirst('Exception: ', '');
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  /// [SIGNUP ONLY] Ye method sirf Signup Screen se call hoga.
  /// UI mein user pehle House Name ya Join code likhega, phir Google button press karega.
  Future<bool> signUpWithGoogle(UserRole role, {String? houseName, String? joinCode}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Validation (Google popup open hone se pehle, bina sign in ke)
      final house = await _validateHouse(role, joinCode: joinCode, houseName: houseName);

      // 2. Google Authentication Step
      await _googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();
      final googleAuth = googleUser.authentication;
      final authorizedUser = await googleUser.authorizationClient.authorizeScopes(['email', 'profile']);

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
      final newUser = await _createProfile(
        uid: uid,
        name: userCredential.user!.displayName ?? 'Google User',
        email: userCredential.user!.email ?? '',
        role: role,
        houseId: house.houseId,
        houseName: house.houseName,
      );

      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(isAuthenticated: true, isLoading: false);
      return true;
    } catch (e) {
      // Agar error ata hai toh Google auth ko wapis logout kardo
      await _auth.signOut();
      await _googleSignIn.signOut();

      final errorMsg = e.toString().replaceFirst('Exception: ', '');
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  // ════════════════════════════════════════════════
  // HELPERS
  // ════════════════════════════════════════════════

  String _generateJoinCode() {
    return (Random().nextInt(900000) + 100000).toString();
  }

  /// houseNames collection ka document ID (lowercase + encoded, '/' se bachne ke liye)
  String _houseKey(String name) => Uri.encodeComponent(name.trim().toLowerCase());

  /// joinCodes/{code} ka single document get. Sign in ki zaroorat nahi.
  /// Return: {ownerId, houseName} ya null agar code galat ho.
  Future<Map<String, dynamic>?> _lookupJoinCode(String code) async {
    final clean = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(clean)) return null;
    final doc = await _firestore.collection('joinCodes').doc(clean).get();
    return doc.exists ? doc.data() : null;
  }

  Future<bool> _isHouseNameTaken(String name) async {
    final doc = await _firestore.collection('houseNames').doc(_houseKey(name)).get();
    return doc.exists;
  }

  /// Role ke hisaab se validation. Sign in se PEHLE chal sakti hai.
  Future<({String? houseId, String? houseName})> _validateHouse(
      UserRole role, {
        String? joinCode,
        String? houseName,
      }) async {
    if (role == UserRole.member) {
      if (joinCode == null || joinCode.trim().isEmpty) {
        throw "Please enter a Join Code provided by the House Owner.";
      }
      final house = await _lookupJoinCode(joinCode);
      if (house == null) throw "Invalid Join Code. Please check with your House Owner.";

      return (houseId: house['ownerId'] as String, houseName: house['houseName'] as String?);
    } else {
      if (houseName == null || houseName.trim().isEmpty) {
        throw "Please provide a House Name or Number.";
      }
      final name = houseName.trim();
      if (await _isHouseNameTaken(name)) {
        throw "Sirf ik hi Owner registered ho skta hai. House '$name' is already registered.";
      }
      return (houseId: null, houseName: name);
    }
  }

  Future<String> _uniqueJoinCode() async {
    while (true) {
      final code = _generateJoinCode();
      final exists = (await _firestore.collection('joinCodes').doc(code).get()).exists;
      if (!exists) return code;
    }
  }

  /// users/{uid} banata hai. Owner ke liye joinCodes aur houseNames bhi
  /// ek hi batch me likhta hai (atomic: house name pehle se ho to poora batch fail).
  Future<User> _createProfile({
    required String uid,
    required String name,
    required String email,
    required UserRole role,
    String? houseId,
    String? houseName,
  }) async {
    final isOwner = role == UserRole.owner;
    final String? code = isOwner ? await _uniqueJoinCode() : null;

    final newUser = User(
      id: uid,
      name: name,
      email: email,
      role: role,
      houseId: isOwner ? uid : houseId,
      houseName: houseName,
      isApproved: isOwner,
      joinCode: code,
    );

    final batch = _firestore.batch();
    batch.set(_firestore.collection('users').doc(uid), newUser.toMap());
    if (isOwner) {
      batch.set(_firestore.collection('joinCodes').doc(code!), {
        'ownerId': uid,
        'houseName': houseName,
      });
      batch.set(_firestore.collection('houseNames').doc(_houseKey(houseName!)), {
        'ownerId': uid,
      });
    }
    await batch.commit();
    return newUser;
  }

  /// Purane owners (jo naye system se pehle bane) ke liye: login pe
  /// joinCodes/houseNames documents khud ban jayenge.
  Future<void> _ensureOwnerIndexes(User user) async {
    if (user.role != UserRole.owner) return;
    try {
      final code = user.joinCode;
      if (code != null && code.isNotEmpty) {
        final ref = _firestore.collection('joinCodes').doc(code);
        if (!(await ref.get()).exists) {
          await ref.set({'ownerId': user.id, 'houseName': user.houseName});
        }
      }
      final name = user.houseName;
      if (name != null && name.trim().isNotEmpty) {
        final ref = _firestore.collection('houseNames').doc(_houseKey(name));
        if (!(await ref.get()).exists) {
          await ref.set({'ownerId': user.id});
        }
      }
    } catch (_) {
      // silent: ye sirf backfill hai, login ko nahi rokna
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
    state = state.copyWith(isAuthenticated: false);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);