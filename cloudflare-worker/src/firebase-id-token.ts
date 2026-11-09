import { createPublicKey, verify as verifySignature } from "node:crypto";
import { ApiError } from "./errors.ts";
import type { FirebaseIdClaims, IdTokenVerifier } from "./types.ts";

const CERT_URL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";
const MAX_CERT_CACHE_MS = 24 * 60 * 60 * 1000;

interface CachedCerts {
  expiresAt: number;
  keys: Record<string, string>;
}

let certCache: CachedCerts | undefined;

function decodeBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function decodeJsonPart<T>(value: string): T {
  try {
    return JSON.parse(new TextDecoder().decode(decodeBase64Url(value))) as T;
  } catch {
    throw new ApiError("unauthenticated", "Firebase ID token is malformed.");
  }
}

function maxAgeMilliseconds(cacheControl: string | null): number {
  const match = cacheControl?.match(/(?:^|,)\s*max-age=(\d+)/i);
  const seconds = match ? Number(match[1]) : 0;
  return Math.min(MAX_CERT_CACHE_MS, Math.max(0, seconds * 1000));
}

export class FirebaseIdTokenVerifier implements IdTokenVerifier {
  constructor(
    private readonly projectId: string,
    private readonly fetcher: typeof fetch = fetch,
    private readonly nowSeconds: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  async verify(token: string): Promise<FirebaseIdClaims> {
    if (typeof token !== "string" || token.length > 16_384) {
      throw new ApiError("unauthenticated", "A valid Firebase ID token is required.");
    }
    const parts = token.split(".");
    if (parts.length !== 3) throw new ApiError("unauthenticated", "Firebase ID token is malformed.");
    const header = decodeJsonPart<{ alg?: string; kid?: string }>(parts[0]);
    if (header.alg !== "RS256" || typeof header.kid !== "string") {
      throw new ApiError("unauthenticated", "Firebase ID token uses an unsupported signature.");
    }
    const cert = (await this.getCerts())[header.kid];
    if (!cert) {
      certCache = undefined;
      const refreshed = (await this.getCerts(true))[header.kid];
      if (!refreshed) throw new ApiError("unauthenticated", "Firebase ID token signing key is unknown.");
      return this.verifyWithCert(parts, refreshed);
    }
    return this.verifyWithCert(parts, cert);
  }

  private verifyWithCert(parts: string[], cert: string): FirebaseIdClaims {
    const signedContent = `${parts[0]}.${parts[1]}`;
    let signatureValid = false;
    try {
      signatureValid = verifySignature(
        "RSA-SHA256",
        Buffer.from(signedContent),
        createPublicKey(cert),
        Buffer.from(decodeBase64Url(parts[2])),
      );
    } catch {
      signatureValid = false;
    }
    if (!signatureValid) throw new ApiError("unauthenticated", "Firebase ID token signature is invalid.");

    const claims = decodeJsonPart<FirebaseIdClaims>(parts[1]);
    const now = this.nowSeconds();
    if (claims.aud !== this.projectId || claims.iss !== `https://securetoken.google.com/${this.projectId}`) {
      throw new ApiError("unauthenticated", "Firebase ID token project does not match.");
    }
    if (typeof claims.sub !== "string" || claims.sub.length === 0 || claims.sub.length > 128 ||
      !Number.isInteger(claims.exp) || claims.exp <= now ||
      !Number.isInteger(claims.iat) || claims.iat > now + 60 ||
      !Number.isInteger(claims.auth_time) || claims.auth_time > now) {
      throw new ApiError("unauthenticated", "Firebase ID token is expired or has invalid claims.");
    }
    return claims;
  }

  private async getCerts(force = false): Promise<Record<string, string>> {
    if (!force && certCache && certCache.expiresAt > Date.now()) return certCache.keys;
    let response: Response;
    try {
      response = await this.fetcher(CERT_URL, { headers: { Accept: "application/json" } });
    } catch {
      throw new ApiError("unavailable", "Firebase signing keys are temporarily unavailable.");
    }
    if (!response.ok) throw new ApiError("unavailable", "Firebase signing keys are temporarily unavailable.");
    const keys = await response.json() as Record<string, string>;
    if (!keys || typeof keys !== "object" || Array.isArray(keys)) {
      throw new ApiError("unavailable", "Firebase signing keys could not be read.");
    }
    const maxAge = maxAgeMilliseconds(response.headers.get("cache-control"));
    certCache = { keys, expiresAt: Date.now() + maxAge };
    return keys;
  }
}

export function clearFirebaseCertCacheForTests(): void {
  certCache = undefined;
}
