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
  constructor(private readonly env: Env, private readonly fetcher: typeof fetch = fetch) {}

  private credentials(): ServiceAccount {
    if (this.account) return this.account;
    try {
      const data = JSON.parse(this.env.GOOGLE_SERVICE_ACCOUNT_JSON ?? "") as ServiceAccount;
      if (!data.client_email || !data.private_key) throw new Error("missing credential fields");
      this.account = data;
      return data;
    } catch {
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
    try {
      const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(fromPem(account.private_key)), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
      const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, Uint8Array.from(new TextEncoder().encode(input)));
      const assertion = `${input}.${b64url(new Uint8Array(signature))}`;
      const response = await this.fetcher(TOKEN_URL, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }) });
      if (!response.ok) throw new Error("token exchange rejected");
      const result = await response.json() as { access_token?: string; expires_in?: number };
      if (!result.access_token) throw new Error("access token missing");
      this.access = { token: result.access_token, expiresAt: Date.now() + (result.expires_in ?? 3600) * 1000 };
      return result.access_token;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError("unavailable", "Google Admin authentication failed.");
    }
  }
}
