import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;

import '../models/house.dart';
import '../models/user.dart' as app;

enum HouseMigrationDisposition { planned, created, alreadyExists, rejected }

class HouseMigrationIssue {
  const HouseMigrationIssue({required this.profileId, required this.reason});

  final String profileId;
  final String reason;
}

class HouseMigrationPlan {
  const HouseMigrationPlan({
    required this.housesToCreate,
    required this.existingHouseIds,
    required this.issues,
  });

  final List<House> housesToCreate;
  final List<String> existingHouseIds;
  final List<HouseMigrationIssue> issues;
}

/// Input row used by the pure legacy migration planner.
class LegacyHouseOwnerProfile {
  const LegacyHouseOwnerProfile({required this.documentId, required this.data});

  final String documentId;
  final Map<String, dynamic> data;
}

/// Plans a migration without making assumptions about inconsistent profiles.
class LegacyHouseMigrationPlanner {
  const LegacyHouseMigrationPlanner._();

  static HouseMigrationPlan plan({
    required Iterable<LegacyHouseOwnerProfile> profiles,
    required Set<String> existingHouseIds,
    required DateTime timestamp,
  }) {
    final owners = profiles
        .where((profile) => profile.data['role'] == app.UserRole.owner.name)
        .toList();
    final issues = <HouseMigrationIssue>[];
    final existing = <String>[];
    final validOwners = <({String uid, String name})>[];
    final seenProfileIds = <String>{};
    final duplicateProfileIds = <String>{};

    for (final profile in owners) {
      final uid = profile.documentId.trim();
      if (!seenProfileIds.add(uid)) {
        duplicateProfileIds.add(uid);
        issues.add(HouseMigrationIssue(
          profileId: uid,
          reason: 'Duplicate owner profile row for the same user document.',
        ));
        continue;
      }
      if (uid.isEmpty || profile.data['id'] != uid) {
        issues.add(HouseMigrationIssue(
          profileId: uid,
          reason: 'Profile id does not match its users document ID.',
        ));
        continue;
      }
      if (profile.data['houseId'] != uid) {
        issues.add(HouseMigrationIssue(
          profileId: uid,
          reason: 'Owner houseId does not match the legacy owner UID.',
        ));
        continue;
      }
      final name = profile.data['houseName'];
      if (name is! String || name.trim().isEmpty) {
        issues.add(HouseMigrationIssue(
          profileId: uid,
          reason: 'Owner profile has no usable houseName.',
        ));
        continue;
      }
      validOwners.add((uid: uid, name: name.trim()));
    }

    // Do not choose between profiles claiming the same normalized legacy name.
    final idsByName = <String, List<String>>{};
    for (final owner in validOwners) {
      idsByName.putIfAbsent(owner.name.toLowerCase(), () => []).add(owner.uid);
    }
    final duplicateNameIds = <String>{};
    for (final ids in idsByName.values.where((ids) => ids.length > 1)) {
      for (final id in ids) {
        duplicateNameIds.add(id);
        issues.add(HouseMigrationIssue(
          profileId: id,
          reason: 'Multiple legacy owner profiles use the same houseName.',
        ));
      }
    }

    final candidates = <House>[];
    for (final owner in validOwners) {
      if (duplicateProfileIds.contains(owner.uid)) continue;
      if (duplicateNameIds.contains(owner.uid)) continue;
      if (existingHouseIds.contains(owner.uid)) {
        existing.add(owner.uid);
        continue;
      }
      candidates.add(House(
        houseId: owner.uid,
        ownerUid: owner.uid,
        name: owner.name,
        mainControllerId: null,
        createdAt: timestamp,
        updatedAt: timestamp,
      ));
    }

    return HouseMigrationPlan(
      housesToCreate: candidates,
      existingHouseIds: existing,
      issues: issues,
    );
  }
}

class CurrentHouseMigrationResult {
  const CurrentHouseMigrationResult({
    required this.disposition,
    this.house,
    this.message,
  });

  final HouseMigrationDisposition disposition;
  final House? house;
  final String? message;
}

/// Firestore access for the House registry foundation.
class HouseService {
  HouseService({
    FirebaseFirestore? firestore,
    firebase.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase.FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final firebase.FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _houses =>
      _firestore.collection('houses');

  Future<House?> getHouseById(String houseId) async {
    final id = houseId.trim();
    if (id.isEmpty) return null;
    final snapshot = await _houses.doc(id).get();
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return House.fromMap(data, documentId: snapshot.id);
  }

  Future<House?> getCurrentUsersHouse(app.User user) {
    final houseId = user.houseId?.trim();
    if (houseId == null || houseId.isEmpty) return Future.value(null);
    return getHouseById(houseId);
  }

  Future<bool> houseExists(String houseId) async {
    final id = houseId.trim();
    if (id.isEmpty) return false;
    return (await _houses.doc(id).get()).exists;
  }

  /// Creates only the signed-in owner's missing legacy registry row.
  ///
  /// Dry-run is the default. The transaction re-reads the legacy user profile,
  /// verifies the UID-based House ID and uses create-only semantics, so a
  /// concurrent or existing House document is never overwritten.
  Future<CurrentHouseMigrationResult> backfillCurrentOwnerHouse({
    bool dryRun = true,
    DateTime? timestamp,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return const CurrentHouseMigrationResult(
        disposition: HouseMigrationDisposition.rejected,
        message: 'Sign in is required to inspect the current House.',
      );
    }

    final userRef = _firestore.collection('users').doc(uid);
    final houseRef = _houses.doc(uid);
    final userSnapshot = await userRef.get();
    final profile = userSnapshot.data();
    final issue = _legacyOwnerIssue(profile, uid);
    if (issue != null) {
      return CurrentHouseMigrationResult(
        disposition: HouseMigrationDisposition.rejected,
        message: issue,
      );
    }

    final existing = await houseRef.get();
    if (existing.exists) {
      return CurrentHouseMigrationResult(
        disposition: HouseMigrationDisposition.alreadyExists,
        message: 'Existing House registry document was left unchanged.',
      );
    }

    final now = timestamp ?? DateTime.now().toUtc();
    final house = House(
      houseId: uid,
      ownerUid: uid,
      name: (profile!['houseName'] as String).trim(),
      mainControllerId: null,
      createdAt: now,
      updatedAt: now,
    );
    if (dryRun) {
      return CurrentHouseMigrationResult(
        disposition: HouseMigrationDisposition.planned,
        house: house,
        message: 'Dry run: House registry document is ready to create.',
      );
    }

    final disposition = await _firestore.runTransaction((transaction) async {
      final latestUser = await transaction.get(userRef);
      final latestProfile = latestUser.data();
      final latestIssue = _legacyOwnerIssue(latestProfile, uid);
      if (latestIssue != null) {
        return HouseMigrationDisposition.rejected;
      }
      final latestHouse = await transaction.get(houseRef);
      if (latestHouse.exists) return HouseMigrationDisposition.alreadyExists;
      transaction.set(houseRef, {
        ...house.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return HouseMigrationDisposition.created;
    });

    return CurrentHouseMigrationResult(
      disposition: disposition,
      house: disposition == HouseMigrationDisposition.created ? house : null,
      message: disposition == HouseMigrationDisposition.created
          ? 'House registry document created.'
          : disposition == HouseMigrationDisposition.rejected
              ? 'Owner profile changed or became inconsistent; no House was created.'
              : 'House registry document already exists and was left unchanged.',
    );
  }

  String? _legacyOwnerIssue(Map<String, dynamic>? profile, String uid) {
    if (profile == null) return 'No users/$uid profile exists.';
    if (profile['role'] != app.UserRole.owner.name) {
      return 'The current user profile is not an owner profile.';
    }
    if (profile['id'] != uid || profile['houseId'] != uid) {
      return 'Owner profile identity is inconsistent; no House ID was inferred.';
    }
    final name = profile['houseName'];
    if (name is! String || name.trim().isEmpty) {
      return 'Owner profile has no usable houseName.';
    }
    return null;
  }
}
