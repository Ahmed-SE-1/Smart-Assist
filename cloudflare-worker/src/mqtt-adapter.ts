import { ApiError } from "./errors.ts";
import type { Env, MqttPublishTransport } from "./types.ts";

/** No broker API/auth pair has been configured for this project; fail closed. */
export class UnconfiguredMqttTransport implements MqttPublishTransport {
  async publish(_topic: string, _payload: string, _qos: 0 | 1 | 2, _retain: boolean): Promise<void> {
    throw new ApiError("unavailable", "EMQX HTTP publishing is not configured for this project.");
  }
}

/**
 * Normalizes and validates an EMQX REST API URL.
 * Accepts:
 * - A base origin: e.g. "https://example.emqx.cloud" or "https://example.emqx.cloud:8084"
 * - An API endpoint: e.g. "https://example.emqx.cloud/api/v5" or "https://example.emqx.cloud/api/v5/"
 *
 * Guarantees the resulting endpoint is exactly `${endpoint}/publish`, never `/api/v5/api/v5/publish`.
 * Rejects invalid protocols, malformed URLs, or unsupported path prefixes.
 */
export function normalizeEmqxPublishUrl(rawUrl: string): string {
  const trimmed = rawUrl.trim();
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new ApiError("invalid-argument", "EMQX_API_URL is not a valid URL.");
  }

  if (parsed.protocol !== "https:") {
    throw new ApiError("invalid-argument", "EMQX_API_URL must use HTTPS.");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new ApiError("invalid-argument", "EMQX_API_URL must not contain credentials, a query, or a fragment.");
  }

  const cleanPath = parsed.pathname.replace(/\/+$/, "");
  if (cleanPath === "" || cleanPath === "/") {
    parsed.pathname = "/api/v5/publish";
  } else if (cleanPath === "/api/v5") {
    parsed.pathname = "/api/v5/publish";
  } else if (cleanPath === "/api/v5/publish") {
    parsed.pathname = "/api/v5/publish";
  } else {
    throw new ApiError(
      "invalid-argument",
      `EMQX_API_URL path "${parsed.pathname}" is unsupported. Expected base origin or ending in "/api/v5".`
    );
  }

  return parsed.toString();
}

/**
 * Publishes MQTT messages via the EMQX Cloud / Enterprise HTTPS REST API (v5 API).
 * Uses Basic Authentication with EMQX Deployment App ID & App Secret.
 */
export class EmqxHttpPublishTransport implements MqttPublishTransport {
  private readonly publishUrl: string;
  private readonly authHeader: string;

  constructor(
    apiUrl: string,
    appId: string,
    apiSecret: string,
    private readonly fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init)
  ) {
    if (!appId.trim() || !apiSecret.trim()) {
      throw new ApiError("invalid-argument", "EMQX Deployment App ID and App Secret are required.");
    }
    this.publishUrl = normalizeEmqxPublishUrl(apiUrl);
    this.authHeader = `Basic ${btoa(`${appId}:${apiSecret}`)}`;
  }

  async publish(topic: string, payload: string, qos: 0 | 1 | 2, retain: boolean): Promise<void> {
    let response: Response;
    try {
      response = await this.fetcher(this.publishUrl, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          Authorization: this.authHeader,
        },
        body: JSON.stringify({
          topic,
          payload,
          qos,
          retain,
        }),
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new ApiError("unavailable", "EMQX publish request could not be completed.");
    }

    if (response.status !== 200) {
      throw new ApiError(
        response.status === 401 || response.status === 403 ? "permission-denied" : "unavailable",
        "EMQX publish was rejected by the broker API."
      );
    }
    let result: unknown;
    try {
      result = await response.json();
    } catch {
      throw new ApiError("unavailable", "EMQX publish response could not be read.");
    }
    if (!result || typeof result !== "object" || typeof (result as { id?: unknown }).id !== "string" || !(result as { id: string }).id) {
      throw new ApiError("unavailable", "EMQX publish response was invalid.");
    }
  }
}

/**
 * Creates an MQTT publish transport based on environment variables.
 * Returns EmqxHttpPublishTransport if EMQX_API_URL, EMQX_API_KEY, and EMQX_API_SECRET
 * are configured, otherwise falls back to UnconfiguredMqttTransport.
 */
export function createMqttTransport(env: Env, fetcher?: typeof fetch): MqttPublishTransport {
  const url = env.EMQX_API_URL?.trim();
  const key = env.EMQX_API_KEY?.trim();
  const secret = env.EMQX_API_SECRET?.trim();
  const configuredValues = [url, key, secret].filter(Boolean).length;
  if (configuredValues !== 0 && configuredValues !== 3) {
    throw new ApiError("unavailable", "EMQX publishing configuration is incomplete.");
  }
  if (url && key && secret) {
    return new EmqxHttpPublishTransport(url, key, secret, fetcher);
  }
  return new UnconfiguredMqttTransport();
}
