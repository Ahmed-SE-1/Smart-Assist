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
  final bool hasSeenOnboarding;
  final bool isFirstTime;
  final bool isHubConnected;

  const AuthState({
    this.isAuthenticated = false,
    this.error,
    this.isLoading = false,
    this.isInitializing = true,
    this.hasSeenOnboarding = false,
    this.isFirstTime = true,
    this.isHubConnected = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? error,
    bool? isLoading,
    bool? isInitializing,
    bool? hasSeenOnboarding,
    bool? isFirstTime,
    bool? isHubConnected,
    bool clearError = false,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
      isInitializing: isInitializing ?? this.isInitializing,
      hasSeenOnboarding: hasSeenOnboarding ?? this.hasSeenOnboarding,
      isFirstTime: isFirstTime ?? this.isFirstTime,
      isHubConnected: isHubConnected ?? this.isHubConnected,
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

      final hasSeenOnboarding = await _storage.hasSeenOnboarding();
      final isFirstTime = await _storage.isFirstTime();
      final isHubConnected = await _storage.isHubConnected();

      final firebaseUser = _auth.currentUser;
      final isLogged = firebaseUser != null;

      if (isLogged) {
        final doc = await _firestore.collection('users').doc(firebaseUser.uid).get();
        if (doc.exists) {
          final user = User.fromMap(doc.data()!);
          ref.read(userProvider.notifier).setUser(user);
        } else {
          // Invalid user state
          await logout();
        }
      }

      state = state.copyWith(
        isAuthenticated: isLogged,
        isInitializing: false,
        hasSeenOnboarding: hasSeenOnboarding,
        isFirstTime: isFirstTime,
        isHubConnected: isHubConnected,
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
      await _storage.setHasSeenOnboarding(true);

      final doc = await _firestore.collection('users').doc(userCredential.user!.uid).get();
      if (doc.exists) {
        final user = User.fromMap(doc.data()!);
        ref.read(userProvider.notifier).setUser(user);
      } else {
        throw "User role data not found in database.";
      }

      state = state.copyWith(isAuthenticated: true, isLoading: false, hasSeenOnboarding: true);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message ?? 'Login failed');
      return false;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> signup(String name, String email, String password, UserRole role, {String? joinCode, String? houseName}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      String? targetHouseId;
      String? targetHouseName;

      // 1. Validation Logic Based on Role
      if (role == UserRole.member) {
        if (joinCode == null || joinCode.trim().isEmpty) throw "Please enter a Join Code provided by the House Owner.";

        final houseQuery = await _firestore.collection('users').where('role', isEqualTo: 'owner').where('joinCode', isEqualTo: joinCode).limit(1).get();
        if (houseQuery.docs.isEmpty) throw "Invalid Join Code. Please check with your House Owner.";

        targetHouseId = houseQuery.docs.first.id;
        targetHouseName = houseQuery.docs.first.data()['houseName'];
      } else {
        if (houseName == null || houseName.trim().isEmpty) throw "Please provide a House Name or Number.";
        targetHouseName = houseName.trim();

        final existingHouseQuery = await _firestore.collection('users').where('role', isEqualTo: 'owner').where('houseName', isEqualTo: targetHouseName).limit(1).get();
        if (existingHouseQuery.docs.isNotEmpty) throw "Sirf ik hi Owner registered ho skta hai. House '$targetHouseName' is already registered.";
      }

      // 2. Auth & Create User
      final userCredential = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      final uid = userCredential.user!.uid;
      await userCredential.user!.updateDisplayName(name);
      await _storage.setHasSeenOnboarding(true);

      final newUser = User(
        id: uid,
        name: name,
        email: email,
        role: role,
        houseId: role == UserRole.owner ? uid : targetHouseId,
        houseName: targetHouseName,
        isApproved: role == UserRole.owner,
        joinCode: role == UserRole.owner ? _generateJoinCode() : null,
      );

      await _firestore.collection('users').doc(uid).set(newUser.toMap());
      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(isAuthenticated: true, isLoading: false, hasSeenOnboarding: true);
      return true;
    } catch (e) {
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

      await _storage.setHasSeenOnboarding(true);
      final user = User.fromMap(doc.data()!);
      ref.read(userProvider.notifier).setUser(user);

      state = state.copyWith(isAuthenticated: true, isLoading: false, hasSeenOnboarding: true);
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
      String? targetHouseId;
      String? targetHouseName;

      // 1. Validation (Google popup open hone se pehle House Name / Join code check hoga)
      if (role == UserRole.member) {
        if (joinCode == null || joinCode.trim().isEmpty) throw "Please enter a Join Code provided by the House Owner.";

        final houseQuery = await _firestore.collection('users').where('role', isEqualTo: 'owner').where('joinCode', isEqualTo: joinCode).limit(1).get();
        if (houseQuery.docs.isEmpty) throw "Invalid Join Code. Please check with your House Owner.";

        targetHouseId = houseQuery.docs.first.id;
        targetHouseName = houseQuery.docs.first.data()['houseName'];
      } else {
        if (houseName == null || houseName.trim().isEmpty) throw "Please provide a House Name or Number.";
        targetHouseName = houseName.trim();

        final existingHouseQuery = await _firestore.collection('users').where('role', isEqualTo: 'owner').where('houseName', isEqualTo: targetHouseName).limit(1).get();
        if (existingHouseQuery.docs.isNotEmpty) throw "Sirf ik hi Owner registered ho skta hai. House '$targetHouseName' is already registered.";
      }

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

      // 4. Check if already completely registered
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        throw "This Google account is already registered. Please login instead.";
      }

      // 5. Create new User Profile in Database
      final newUser = User(
        id: uid,
        name: userCredential.user!.displayName ?? 'Google User',
        email: userCredential.user!.email ?? '',
        role: role,
        houseId: role == UserRole.owner ? uid : targetHouseId,
        houseName: targetHouseName,
        isApproved: role == UserRole.owner,
        joinCode: role == UserRole.owner ? _generateJoinCode() : null,
      );

      await _firestore.collection('users').doc(uid).set(newUser.toMap());
      ref.read(userProvider.notifier).setUser(newUser);
      await _storage.setHasSeenOnboarding(true);

      state = state.copyWith(isAuthenticated: true, isLoading: false, hasSeenOnboarding: true);
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

  Future<void> simulateHubConnection({
    bool screenReader = false,
    bool voiceFeedback = false,
    bool visualAlerts = false,
  }) async {
    state = state.copyWith(isLoading: true);
    await Future.delayed(const Duration(seconds: 2));

    final randomPart = DateTime.now().millisecondsSinceEpoch.toString().substring(8);
    final hubId = "RPI_$randomPart";

    await _storage.setHubId(hubId);
    await _storage.setHubConnected(true);
    await _storage.saveAccessibilitySettings(screenReader: screenReader, voiceFeedback: voiceFeedback, visualAlerts: visualAlerts);
    await _storage.setFirstTime(false);

    state = state.copyWith(isLoading: false, isHubConnected: true, isFirstTime: false);
  }

  Future<void> completeOnboarding() async {
    await _storage.setHasSeenOnboarding(true);
    state = state.copyWith(hasSeenOnboarding: true);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);