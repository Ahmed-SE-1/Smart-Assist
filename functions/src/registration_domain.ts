export class RegistrationDomainError extends Error {
  constructor(
    readonly reason: "invalid-join-code" | "duplicate-profile" | "invalid-owner" | "invalid-house-name",
  ) {
    super(reason);
  }
}

export function normalizeHouseName(value: unknown): string {
  if (typeof value !== "string") {
    throw new RegistrationDomainError("invalid-house-name");
  }
  const name = value.trim();
  if (!name || name.length > 80) {
    throw new RegistrationDomainError("invalid-house-name");
  }
  return name;
}

/** Matches the existing Dart Uri.encodeComponent(normalizedName) index key. */
export function houseNameIndexKey(name: string): string {
  return encodeURIComponent(name.trim().toLowerCase());
}

export function assertProfileDoesNotExist(exists: boolean): void {
  if (exists) throw new RegistrationDomainError("duplicate-profile");
}

export interface AuthenticatedIdentity {
  uid: string;
  email: string;
  avatarUrl: string | null;
}

export function buildOwnerProfile(args: {
  identity: AuthenticatedIdentity;
  displayName: unknown;
  houseName: string;
  joinCode: string;
}): Record<string, unknown> {
  const name = typeof args.displayName === "string" ? args.displayName.trim() : "";
  return {
    id: args.identity.uid,
    name: name || "SmartAssist User",
    email: args.identity.email,
    avatarUrl: args.identity.avatarUrl,
    role: "owner",
    houseId: args.identity.uid,
    houseName: args.houseName,
    isApproved: true,
    joinCode: args.joinCode,
  };
}

export function buildMemberProfile(args: {
  identity: AuthenticatedIdentity;
  displayName: unknown;
  joinCodeDocument: Record<string, unknown> | null;
  ownerProfile: Record<string, unknown> | null;
}): Record<string, unknown> {
  const index = args.joinCodeDocument;
  const owner = args.ownerProfile;
  const ownerUid = index?.ownerId;
  const houseName = index?.houseName;
  const isValid =
    typeof ownerUid === "string" &&
    ownerUid.length > 0 &&
    typeof houseName === "string" &&
    houseName.trim().length > 0 &&
    owner !== null &&
    owner.id === ownerUid &&
    owner.role === "owner" &&
    owner.houseId === ownerUid &&
    owner.isApproved === true &&
    owner.houseName === houseName;
  if (!isValid) throw new RegistrationDomainError("invalid-join-code");

  const name = typeof args.displayName === "string" ? args.displayName.trim() : "";
  return {
    id: args.identity.uid,
    name: name || "SmartAssist User",
    email: args.identity.email,
    avatarUrl: args.identity.avatarUrl,
    role: "member",
    houseId: ownerUid,
    houseName,
    isApproved: false,
    joinCode: null,
  };
}

export function houseRegistryConflict(
  houseId: string,
  expected: { ownerUid: string; name: string },
  existing: Record<string, unknown>,
): string | null {
  if (
    existing.houseId !== houseId ||
    existing.ownerUid !== expected.ownerUid ||
    existing.name !== expected.name
  ) {
    return "Existing House document does not match its legacy owner profile.";
  }
  return null;
}

/** Fields shared by the Firestore House model and the registration callable. */
export function buildHouseRegistryEntry(
  houseId: string,
  ownerUid: string,
  name: string,
): Record<string, unknown> {
  return {
    houseId,
    ownerUid,
    name,
    mainControllerId: null,
  };
}
