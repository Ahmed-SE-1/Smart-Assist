import { ApiError } from "./errors.ts";
import type { Env } from "./types.ts";

interface ServiceAccount { client_email: string; private_key: string; project_id?: string; }
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const AUTH_SCOPE = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/firebase";

function b64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
function fromPem(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}
function jsonSegment(value: unknown): string { return b64url(JSON.stringify(value)); }

export class GoogleAdminAuth {
  private account?: ServiceAccount;
  private access?: { token: string; expiresAt: number };
  constructor(private readonly env: Env, private readonly fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init)) {}

  private credentials(): ServiceAccount {
    if (this.account) return this.account;
    try {
      const data = JSON.parse(this.env.GOOGLE_SERVICE_ACCOUNT_JSON ?? "") as ServiceAccount;
      if (typeof data.client_email !== "string" || !data.client_email.includes("@") ||
        typeof data.private_key !== "string" || !data.private_key.includes("-----BEGIN PRIVATE KEY-----")) {
        throw new Error("missing credential fields");
      }
      this.account = data;
      return data;
    } catch {
      console.error("google_auth_credentials_invalid", { category: "missing_or_invalid_secret" });
      throw new ApiError("unavailable", "Google Admin credentials are not configured.");
    }
  }

  async accessToken(): Promise<string> {
    if (this.access && this.access.expiresAt > Date.now() + 30_000) return this.access.token;
    const account = this.credentials();
    const now = Math.floor(Date.now() / 1000);
    const header = jsonSegment({ alg: "RS256", typ: "JWT" });
    const claims = jsonSegment({ iss: account.client_email, scope: AUTH_SCOPE, aud: TOKEN_URL, iat: now, exp: now + 3600 });
    const input = `${header}.${claims}`;
    let assertion: string;
    try {
      const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(fromPem(account.private_key)), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
      const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, Uint8Array.from(new TextEncoder().encode(input)));
      assertion = `${input}.${b64url(new Uint8Array(signature))}`;
    } catch {
      console.error("google_auth_signing_failed", { category: "private_key_import_or_signing" });
      throw new ApiError("unavailable", "Google Admin authentication failed.");
    }
    let response: Response;
    try {
      response = await this.fetcher(TOKEN_URL, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }), signal: AbortSignal.timeout(8_000) });
    } catch (error) {
      console.error("google_auth_oauth_failed", { category: error instanceof Error && error.name === "AbortError" ? "timeout" : error instanceof TypeError ? "network" : "fetch_error" });
      throw new ApiError("unavailable", "Google Admin authentication failed.");
    }
    if (!response.ok) {
      console.error("google_auth_oauth_rejected", { status: response.status });
      throw new ApiError("unavailable", "Google Admin authentication failed.");
    }
    try {
      const result = await response.json() as { access_token?: string; expires_in?: number };
      if (typeof result.access_token !== "string" || !result.access_token || !Number.isFinite(result.expires_in ?? 3600) || (result.expires_in ?? 3600) <= 0) throw new Error("invalid response");
      if (!result.access_token) throw new Error("access token missing");
      this.access = { token: result.access_token, expiresAt: Date.now() + (result.expires_in ?? 3600) * 1000 };
      return result.access_token;
    } catch {
      console.error("google_auth_oauth_response_invalid", { category: "malformed_json_or_fields" });
      throw new ApiError("unavailable", "Google Admin authentication failed.");
    }
  }
}
