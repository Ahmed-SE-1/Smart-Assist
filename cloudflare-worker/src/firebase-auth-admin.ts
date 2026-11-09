import { ApiError } from "./errors.ts";
import type { AuthAdmin, Env, FirebaseAccount } from "./types.ts";
import { GoogleAdminAuth } from "./google-auth.ts";

function b64(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function privateKeyBytes(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(body); return Uint8Array.from(binary, c => c.charCodeAt(0));
}
type UserInfo = { localId: string; disabled?: boolean; validSince?: string; customAttributes?: string };

export class FirebaseAuthAdmin implements AuthAdmin {
  constructor(private readonly env: Env, private readonly google: GoogleAdminAuth, private readonly fetcher: typeof fetch = fetch) {}

  async getUser(uid: string): Promise<FirebaseAccount | null> {
    const response = await this.call("accounts:lookup", { localId: [uid] });
    if (response.status === 404) return null;
    if (!response.ok) {
      const body = await response.clone().json().catch(() => ({})) as { error?: { message?: string } };
      if (body.error?.message === "USER_NOT_FOUND") return null;
      throw apiUpstream(response.status, "Firebase Auth lookup failed.");
    }
    const body = await response.json() as { users?: UserInfo[] };
    const user = body.users?.[0];
    return user ? this.account(user) : null;
  }

  async createUser(uid: string): Promise<FirebaseAccount> {
    const response = await this.call("accounts", { localId: uid, disabled: false });
    if (!response.ok) throw apiUpstream(response.status, "Firebase Auth user creation failed.");
    return this.account(await response.json() as UserInfo);
  }

  async updateUser(uid: string, update: { customClaims?: Record<string, unknown>; disabled?: boolean; revokeBeforeSeconds?: number }): Promise<void> {
    const body: Record<string, unknown> = { localId: uid };
    if (update.customClaims) body.customAttributes = JSON.stringify(update.customClaims);
    if (update.disabled !== undefined) body.disableUser = update.disabled;
    if (update.revokeBeforeSeconds !== undefined) body.validSince = String(update.revokeBeforeSeconds);
    const response = await this.call("accounts:update", body);
    if (!response.ok) throw apiUpstream(response.status, "Firebase Auth user update failed.");
  }

  async createCustomToken(uid: string, claims: Record<string, unknown>): Promise<string> {
    const raw = this.env.GOOGLE_SERVICE_ACCOUNT_JSON;
    if (!raw) throw new ApiError("unavailable", "Firebase custom-token signing is not configured.");
    let account: { client_email: string; private_key: string };
    try { account = JSON.parse(raw) as typeof account; } catch { throw new ApiError("unavailable", "Firebase custom-token signing is not configured."); }
    const now = Math.floor(Date.now() / 1000);
    const enc = (v: unknown) => b64(JSON.stringify(v));
    const body = `${enc({ alg: "RS256", typ: "JWT" })}.${enc({ iss: account.client_email, sub: account.client_email, aud: "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit", iat: now, exp: now + 3600, uid, claims })}`;
    try {
      const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(privateKeyBytes(account.private_key)), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
      return `${body}.${b64(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, Uint8Array.from(new TextEncoder().encode(body)))))}`;
    } catch { throw new ApiError("unavailable", "Firebase custom-token signing failed."); }
  }

  async assertActiveToken(uid: string, authTimeSeconds: number): Promise<void> {
    const user = await this.getUser(uid);
    if (!user || user.disabled || authTimeSeconds < user.validSinceSeconds) throw new ApiError("unauthenticated", "Firebase ID token has been revoked or disabled.");
  }

  private account(user: UserInfo): FirebaseAccount {
    let customClaims: Record<string, unknown> = {};
    try { customClaims = user.customAttributes ? JSON.parse(user.customAttributes) as Record<string, unknown> : {}; } catch { /* malformed claims remain empty */ }
    return { uid: user.localId, disabled: user.disabled === true, validSinceSeconds: Number(user.validSince ?? 0), customClaims };
  }
  private async call(operation: string, body: Record<string, unknown>): Promise<Response> {
    const url = `https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(this.env.FIREBASE_PROJECT_ID)}/${operation}`;
    try {
      return await this.fetcher(url, { method: "POST", headers: { Authorization: `Bearer ${await this.google.accessToken()}`, "content-type": "application/json", ...(this.env.FIREBASE_WEB_API_KEY ? { "x-goog-api-key": this.env.FIREBASE_WEB_API_KEY } : {}) }, body: JSON.stringify(body) });
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError("unavailable", "Firebase Auth is temporarily unavailable.");
    }
  }
}
function apiUpstream(status: number, message: string): ApiError {
  return new ApiError(status === 403 ? "permission-denied" : status === 404 ? "not-found" : status === 409 ? "already-exists" : status >= 500 ? "unavailable" : "internal", message);
}
