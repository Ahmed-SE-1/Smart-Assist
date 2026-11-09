import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/user.dart';
import './accessibility_provider.dart';
import './automation_provider.dart';
import './smart_home_provider.dart';
import './theme_provider.dart';
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
  final firebase.FirebaseAuth _auth = firebase.FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSubscription;

  @override
  AuthState build() {
    ref.onDispose(() => _userSubscription?.cancel());
    Future.microtask(_checkLoginStatus);
    return const AuthState();
  }

  void _listenToUserProfile(String uid) {
    _userSubscription?.cancel();
    _userSubscription = _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(
          (doc) {
            final data = doc.data();
            if (doc.exists && data != null && data['id'] == uid) {
              final user = User.fromMap(data);
              ref.read(userProvider.notifier).setUser(user);
              ref.read(themeProvider.notifier).syncFromUserDoc(data);
              ref.read(voiceFeedbackProvider.notifier).syncFromUserDoc(data);
              ref.read(showTextFeedbackProvider.notifier).syncFromUserDoc(data);
              state = state.copyWith(isPendingApproval: !user.isApproved);
            }
          },
          onError: (_) {},
        );
  }

  Future<void> _checkLoginStatus() async {
    try {
      final firebaseUser = _auth.currentUser;
      var isLogged = firebaseUser != null;

      if (isLogged) {
        final doc =
            await _firestore.collection('users').doc(firebaseUser.uid).get();
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final user = User.fromMap(data);
          ref.read(userProvider.notifier).setUser(user);
          ref.read(themeProvider.notifier).syncFromUserDoc(data);
          ref.read(voiceFeedbackProvider.notifier).syncFromUserDoc(data);
          ref.read(showTextFeedbackProvider.notifier).syncFromUserDoc(data);
          unawaited(_ensureOwnerIndexes(user));
          state = state.copyWith(isPendingApproval: !user.isApproved);
          _listenToUserProfile(user.id);
        } else {
          // Auth account exists but Firestore profile is missing.
          // Sign out so the user is returned to login rather than
          // being treated as authenticated with no profile.
          await logout();
          isLogged = false;
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
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final user = User.fromMap(data);
        ref.read(userProvider.notifier).setUser(user);
        ref.read(themeProvider.notifier).syncFromUserDoc(data);
        ref.read(voiceFeedbackProvider.notifier).syncFromUserDoc(data);
        ref.read(showTextFeedbackProvider.notifier).syncFromUserDoc(data);
        unawaited(_ensureOwnerIndexes(user));
        state = state.copyWith(isPendingApproval: !user.isApproved);
        _listenToUserProfile(user.id);
      } else {
        await _auth.signOut();
        throw "User profile not found in database. Please register your account first.";
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

    // ── Local validation (no Firebase calls) ──
    if (role == UserRole.owner) {
      if (houseName == null || houseName.trim().isEmpty) {
        state = state.copyWith(
          isLoading: false,
          error: 'Please provide a House Name or Number.',
        );
        return false;
      }
    } else {
      if (joinCode == null || joinCode.trim().isEmpty) {
        state = state.copyWith(
          isLoading: false,
          error: 'Please enter a Join Code provided by the House Owner.',
        );
        return false;
      }
      if (!RegExp(r'^\d{6}$').hasMatch(joinCode.trim())) {
        state = state.copyWith(
          isLoading: false,
          error: 'Join Code must be exactly 6 digits.',
        );
        return false;
      }
    }

    // ── 1. Create Firebase Auth account first ──
    firebase.User? pendingUser;
    bool firestoreCommitted = false;
    try {
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

      // ── 2. Validate house (now authenticated — Firestore reads succeed) ──
      final house = await _validateHouse(
        role,
        joinCode: joinCode,
        houseName: houseName,
      );

      // ── 3. Atomic Firestore document creation (Spark Plan compliant) ──
      final newUser = await _createProfile(
        uid: createdUser.uid,
        name: name,
        email: email,
        role: role,
        houseId: house.houseId,
        houseName: house.houseName,
        memberJoinCode: role == UserRole.member ? joinCode?.trim() : null,
      );
      firestoreCommitted = true;
      pendingUser = null; // Profile created successfully, do not delete auth user

      ref.read(userProvider.notifier).setUser(newUser);
      _listenToUserProfile(newUser.id);

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !newUser.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      // ── Safe cleanup: only delete the auth account we just created ──
      if (pendingUser != null && !firestoreCommitted) {
        // Verify that the Firestore profile was NOT partially committed
        // before deleting the auth account.
        try {
          final profileDoc = await _firestore
              .collection('users')
              .doc(pendingUser.uid)
              .get();
          if (!profileDoc.exists) {
            // No Firestore profile — safe to remove the orphaned auth account.
            await pendingUser.delete();
          }
          // If the profile DOES exist despite the error, keep both the
          // auth account and profile intact for manual recovery.
        } catch (_) {
          // Cannot confirm Firestore state (network issue, etc.).
          // Preserve the auth account rather than risk data loss.
        }
      }
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
      if (!doc.exists || doc.data() == null) {
        await _auth.signOut();
        await _googleSignIn.signOut();
        throw "User not registered. Please sign up to register your House or Join Code first.";
      }

      final data = doc.data()!;
      final user = User.fromMap(data);
      ref.read(userProvider.notifier).setUser(user);
      ref.read(themeProvider.notifier).syncFromUserDoc(data);
      ref.read(voiceFeedbackProvider.notifier).syncFromUserDoc(data);
      ref.read(showTextFeedbackProvider.notifier).syncFromUserDoc(data);
      unawaited(_ensureOwnerIndexes(user));
      _listenToUserProfile(user.id);

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !user.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      final errorMsg = _friendlyError(e);
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  /// [SIGNUP ONLY] Ye method sirf Signup Screen se call hoga.
  Future<bool> signUpWithGoogle(
    UserRole role, {
    String? houseName,
    String? joinCode,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Validation before signing into Google
      final house = await _validateHouse(
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

      // 3. Check if already registered
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        throw "This Google account is already registered. Please login instead.";
      }

      // 4. Create new User Profile in Database (Spark Plan compliant)
      final displayName = userCredential.user!.displayName ?? 'Google User';
      final email = userCredential.user!.email ?? '';
      final newUser = await _createProfile(
        uid: uid,
        name: displayName,
        email: email,
        role: role,
        houseId: house.houseId,
        houseName: house.houseName,
        memberJoinCode: role == UserRole.member ? joinCode?.trim() : null,
      );

      ref.read(userProvider.notifier).setUser(newUser);
      _listenToUserProfile(newUser.id);

      state = state.copyWith(
        isAuthenticated: true,
        isPendingApproval: !newUser.isApproved,
        isLoading: false,
      );
      return true;
    } catch (e) {
      await _auth.signOut();
      await _googleSignIn.signOut();

      final errorMsg = _friendlyError(e);
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  // ════════════════════════════════════════════════
  // HELPERS (SPARK COMPATIBLE)
  // ════════════════════════════════════════════════

  String _generateJoinCode() {
    return (Random().nextInt(900000) + 100000).toString();
  }

  String _houseKey(String name) => Uri.encodeComponent(name.trim().toLowerCase());

  Future<Map<String, dynamic>?> _lookupJoinCode(String code) async {
    final clean = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(clean)) return null;
    final doc = await _firestore.collection('joinCodes').doc(clean).get();
    return doc.exists ? doc.data() : null;
  }

  Future<bool> _isHouseNameTaken(String name) async {
    final doc =
        await _firestore.collection('houseNames').doc(_houseKey(name)).get();
    return doc.exists;
  }

  Future<({String? houseId, String? houseName})> _validateHouse(
    UserRole role, {
    String? joinCode,
    String? houseName,
  }) async {
    if (role == UserRole.member) {
      if (joinCode == null || joinCode.trim().isEmpty) {
        throw 'Please enter a Join Code provided by the House Owner.';
      }
      final cleanCode = joinCode.trim();
      if (!RegExp(r'^\d{6}$').hasMatch(cleanCode)) {
        throw 'Join Code must be exactly 6 digits.';
      }
      final house = await _lookupJoinCode(cleanCode);
      if (house == null) {
        throw 'Invalid Join Code. Please check with your House Owner.';
      }
      final ownerId = house['ownerId'] as String?;
      final hName = house['houseName'] as String?;
      if (ownerId == null || ownerId.isEmpty) {
        throw 'Invalid House record associated with this Join Code.';
      }
      return (houseId: ownerId, houseName: hName);
    } else {
      if (houseName == null || houseName.trim().isEmpty) {
        throw 'Please provide a House Name or Number.';
      }
      final name = houseName.trim();
      if (await _isHouseNameTaken(name)) {
        throw 'House "$name" is already registered. Please choose a different name.';
      }
      return (houseId: null, houseName: name);
    }
  }

  Future<String> _uniqueJoinCode() async {
    for (int i = 0; i < 10; i++) {
      final code = _generateJoinCode();
      final exists =
          (await _firestore.collection('joinCodes').doc(code).get()).exists;
      if (!exists) return code;
    }
    throw 'Could not generate a unique Join Code. Please try again.';
  }

  Future<User> _createProfile({
    required String uid,
    required String name,
    required String email,
    required UserRole role,
    String? houseId,
    String? houseName,
    String? memberJoinCode,
  }) async {
    final isOwner = role == UserRole.owner;
    final String? code = isOwner ? await _uniqueJoinCode() : memberJoinCode;
    final effectiveHouseId = isOwner ? uid : houseId;

    final newUser = User(
      id: uid,
      name: name,
      email: email,
      role: role,
      houseId: effectiveHouseId,
      houseName: houseName,
      isApproved: isOwner,
      joinCode: code,
    );

    final batch = _firestore.batch();
    batch.set(_firestore.collection('users').doc(uid), newUser.toMap());

    if (isOwner) {
      batch.set(_firestore.collection('houses').doc(uid), {
        'houseId': uid,
        'ownerUid': uid,
        'name': houseName,
        'mainControllerId': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
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

  String _friendlyError(Object error) {
    if (error is firebase.FirebaseAuthException) {
      return error.message ?? 'Authentication failed. Please try again.';
    }
    if (error is FirebaseException) {
      if (error.code == 'permission-denied') {
        return 'Access denied. Please check your House credentials and approval.';
      }
      return error.message ?? 'Database error. Please try again.';
    }
    if (error is String) return error;
    return 'Authentication could not be completed. Please try again.';
  }

  Future<void> _ensureOwnerIndexes(User user) async {
    if (user.role != UserRole.owner) return;
    try {
      final code = user.joinCode;
      if (code != null && code.isNotEmpty) {
        final ref = _firestore.collection('joinCodes').doc(code);
        final snap = await ref.get();
        if (!snap.exists) {
          await ref.set({'ownerId': user.id, 'houseName': user.houseName});
        }
      }
      final name = user.houseName;
      if (name != null && name.trim().isNotEmpty) {
        final ref = _firestore.collection('houseNames').doc(_houseKey(name));
        final snap = await ref.get();
        if (!snap.exists) {
          await ref.set({'ownerId': user.id});
        }
      }
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
    _userSubscription?.cancel();
    await _auth.signOut();
    await _googleSignIn.signOut();
    ref.read(userProvider.notifier).clearUser();
    await ref.read(themeProvider.notifier).resetToDefaults();
    await ref.read(voiceFeedbackProvider.notifier).resetToDefaults();
    await ref.read(showTextFeedbackProvider.notifier).resetToDefaults();
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

final firebaseAuthenticatedProvider = Provider<bool>(
  (ref) => firebase.FirebaseAuth.instance.currentUser != null,
);
