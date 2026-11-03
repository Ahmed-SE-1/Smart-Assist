import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

export function requireAuthenticated(request: CallableRequest<unknown>): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in is required.");
  }
  return uid;
}

/** Restricts one-off legacy migration to operators provisioned out of band. */
export function requireHouseMigrationAdmin(
  request: CallableRequest<unknown>,
): string {
  const uid = requireAuthenticated(request);
  if (request.auth?.token.houseMigrationAdmin !== true) {
    throw new HttpsError("permission-denied", "House migration operator access is required.");
  }
  return uid;
}

/** Shared authorization check for future owner-only House operations. */
export async function requireHouseOwner(uid: string, houseId: string): Promise<void> {
  const user = await getFirestore().collection("users").doc(uid).get();
  const data = user.data();
  if (
    !data ||
    data.id !== uid ||
    data.role !== "owner" ||
    data.houseId !== houseId ||
    data.isApproved !== true
  ) {
    throw new HttpsError("permission-denied", "House owner access is required.");
  }
}
