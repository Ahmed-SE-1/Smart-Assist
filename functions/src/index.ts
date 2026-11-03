import { initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { requireAuthenticated, requireHouseMigrationAdmin } from "./auth.js";

initializeApp();

/// Authenticated deployment probe. It returns no project secrets or user data.
export const healthCheck = onCall((request) => {
  let uid: string;
  try {
    uid = requireAuthenticated(request);
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    throw new HttpsError("internal", "Health check failed.");
  }
  return { ok: true, authenticated: true, uid };
});

/**
 * Explicit, operator-only, dry-run-first backfill for legacy owner profiles.
 * This does not pair controllers or Nodes and is never run automatically.
 */
export const migrateLegacyHouses = onCall(async (request) => {
  requireHouseMigrationAdmin(request);
  const input = request.data;
  const dryRun =
    typeof input !== "object" ||
    input === null ||
    (input as Record<string, unknown>).dryRun !== false;

  const db = getFirestore();
  const [ownerSnapshot, houseSnapshot] = await Promise.all([
    db.collection("users").where("role", "==", "owner").get(),
    db.collection("houses").get(),
  ]);
  const existingIds = new Set(houseSnapshot.docs.map((doc) => doc.id));
  const issues: Array<{ profileId: string; reason: string }> = [];
  const existingHouseIds: string[] = [];
  const validOwners: Array<{ uid: string; name: string }> = [];

  for (const doc of ownerSnapshot.docs) {
    const data = doc.data();
    const uid = doc.id;
    if (data.id !== uid || data.houseId !== uid) {
      issues.push({
        profileId: uid,
        reason: "Owner profile identity or legacy House ID is inconsistent.",
      });
      continue;
    }
    if (typeof data.houseName !== "string" || !data.houseName.trim()) {
      issues.push({ profileId: uid, reason: "Owner profile has no usable houseName." });
      continue;
    }
    validOwners.push({ uid, name: data.houseName.trim() });
  }

  const idsByName = new Map<string, string[]>();
  for (const owner of validOwners) {
    const normalized = owner.name.toLowerCase();
    idsByName.set(normalized, [...(idsByName.get(normalized) ?? []), owner.uid]);
  }
  const duplicateNameIds = new Set<string>();
  for (const ids of idsByName.values()) {
    if (ids.length < 2) continue;
    for (const uid of ids) {
      duplicateNameIds.add(uid);
      issues.push({
        profileId: uid,
        reason: "Multiple legacy owner profiles use the same houseName.",
      });
    }
  }

  const candidates = validOwners.filter((owner) => {
    if (duplicateNameIds.has(owner.uid)) return false;
    if (existingIds.has(owner.uid)) {
      existingHouseIds.push(owner.uid);
      return false;
    }
    return true;
  });

  let created = 0;
  let alreadyExists = existingHouseIds.length;
  if (!dryRun) {
    for (const candidate of candidates) {
      const userRef = db.collection("users").doc(candidate.uid);
      const houseRef = db.collection("houses").doc(candidate.uid);
      const result = await db.runTransaction(async (transaction) => {
        const userDoc = await transaction.get(userRef);
        const houseDoc = await transaction.get(houseRef);
        if (houseDoc.exists) return "exists" as const;
        const user = userDoc.data();
        if (
          !userDoc.exists ||
          user?.role !== "owner" ||
          user.id !== candidate.uid ||
          user.houseId !== candidate.uid ||
          typeof user.houseName !== "string" ||
          user.houseName.trim() !== candidate.name
        ) {
          return "changed" as const;
        }
        transaction.create(houseRef, {
          houseId: candidate.uid,
          ownerUid: candidate.uid,
          name: candidate.name,
          mainControllerId: null,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        return "created" as const;
      });

      if (result === "created") created++;
      if (result === "exists") alreadyExists++;
      if (result === "changed") {
        issues.push({
          profileId: candidate.uid,
          reason: "Owner profile changed after planning; House was not created.",
        });
      }
    }
  }

  return {
    dryRun,
    plannedCount: candidates.length,
    createdCount: created,
    alreadyExistsCount: alreadyExists,
    candidates: candidates.map(({ uid, name }) => ({ houseId: uid, ownerUid: uid, name })),
    issues,
  };
});
