export type ApiErrorCode =
  | "unauthenticated"
  | "permission-denied"
  | "invalid-argument"
  | "not-found"
  | "already-exists"
  | "failed-precondition"
  | "resource-exhausted"
  | "unavailable"
  | "internal";

const statusByCode: Record<ApiErrorCode, number> = {
  unauthenticated: 401,
  "permission-denied": 403,
  "invalid-argument": 400,
  "not-found": 404,
  "already-exists": 409,
  "failed-precondition": 412,
  "resource-exhausted": 429,
  unavailable: 503,
  internal: 500,
};

export class ApiError extends Error {
  readonly status: number;

  constructor(readonly code: ApiErrorCode, message: string, statusOverride?: number) {
    super(message);
    this.name = "ApiError";
    this.status = statusOverride ?? statusByCode[code];
  }
}

export function mapFirebaseCode(code: string): ApiErrorCode {
  if (code === "unauthenticated") return "unauthenticated";
  if (code === "permission-denied") return "permission-denied";
  if (code === "invalid-argument") return "invalid-argument";
  if (code === "not-found") return "not-found";
  if (code === "already-exists") return "already-exists";
  if (code === "failed-precondition") return "failed-precondition";
  if (code === "resource-exhausted") return "resource-exhausted";
  return "internal";
}
