import { ApiError } from "./errors.ts";
import type { Env, PairingSnapshot, PairingStore, PairingTransaction } from "./types.ts";
import { GoogleAdminAuth } from "./google-auth.ts";

type Value = Record<string, unknown>;
interface Ref { collection: string; id: string; }
interface Write { update?: Value; delete?: string; updateMask?: { fieldPaths: string[] }; currentDocument?: { exists: boolean }; }

function encode(value: unknown): Value {
  if (value === null) return { nullValue: null };
  if (typeof value === "string") return { stringValue: value };
  if (typeof value === "boolean") return { booleanValue: value };
  if (typeof value === "number") return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encode) } };
  if (typeof value === "object") return { mapValue: { fields: encodeFields(value as Value) } };
  throw new ApiError("invalid-argument", "Unsupported Firestore value.");
}
function encodeFields(data: Value): Record<string, Value> {
  return Object.fromEntries(Object.entries(data).map(([key, value]) => [key, encode(value)]));
}
function decode(value: Value | undefined): unknown {
  if (!value) return undefined;
  if ("nullValue" in value) return null;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return value.doubleValue;
  if ("timestampValue" in value) return new Date(String(value.timestampValue));
  if ("arrayValue" in value) return (((value.arrayValue as Value).values ?? []) as Value[]).map(decode);
  if ("mapValue" in value) return decodeFields(((value.mapValue as Value).fields ?? {}) as Record<string, Value>);
  return undefined;
}
function decodeFields(fields: Record<string, Value> = {}): Value {
  return Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, decode(value)]));
}
function refName(projectId: string, ref: Ref): string {
  if (!/^[A-Za-z0-9_-]{1,150}$/.test(ref.collection) || !ref.id || ref.id.includes("/")) throw new ApiError("invalid-argument", "Invalid Firestore document reference.");
  return `projects/${projectId}/databases/(default)/documents/${ref.collection}/${encodeURIComponent(ref.id)}`;
}

export class FirestoreRestStore implements PairingStore {
  private readonly root: string;
  constructor(private readonly projectId: string, private readonly auth: GoogleAdminAuth, private readonly fetcher: typeof fetch = fetch) {
    this.root = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;
  }
  doc(collection: string, id: string): object { return { collection, id } satisfies Ref; }

  async get(collection: string, id: string): Promise<Value | undefined> {
    const ref = { collection, id };
    const response = await this.request(`${this.root}/${collection}/${encodeURIComponent(id)}`);
    if (response.status === 404) return undefined;
    if (!response.ok) throw await firestoreError(response);
    return decodeFields(((await response.json()) as Value).fields as Record<string, Value>);
  }

  async query(collection: string, structuredQuery: Record<string, unknown>): Promise<Array<{ id: string; data: Value }>> {
    const response = await this.request(`${this.root}:runQuery`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ structuredQuery: { ...structuredQuery, from: [{ collectionId: collection }] } }) });
    if (!response.ok) throw await firestoreError(response);
    const rows = await response.json() as Array<{ document?: { name: string; fields?: Record<string, Value> } }>;
    return rows.flatMap(row => row.document ? [{ id: row.document.name.split("/").pop()!, data: decodeFields(row.document.fields) }] : []);
  }

  async runTransaction<T>(operation: (transaction: PairingTransaction) => Promise<T>): Promise<T> {
    for (let attempt = 0; attempt < 5; attempt++) {
      const begin = await this.request(`${this.root}:beginTransaction`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ options: { readWrite: {} } }) });
      if (!begin.ok) throw await firestoreError(begin);
      const transactionId = String(((await begin.json()) as Value).transaction);
      const writes: Write[] = [];
      const tx: PairingTransaction = {
        get: async raw => {
          const ref = raw as Ref;
          const response = await this.request(`${this.root}/${ref.collection}/${encodeURIComponent(ref.id)}?transaction=${encodeURIComponent(transactionId)}`);
          if (response.status === 404) return snapshot(false);
          if (!response.ok) throw await firestoreError(response);
          const data = await response.json() as { fields?: Record<string, Value> };
          return snapshot(true, decodeFields(data.fields));
        },
        create: (raw, data) => {
          const ref = raw as Ref;
          writes.push({ update: { name: refName(this.projectId, ref), fields: encodeFields(data) }, currentDocument: { exists: false } });
        },
        update: (raw, data) => {
          const ref = raw as Ref;
          writes.push({ update: { name: refName(this.projectId, ref), fields: encodeFields(data) }, updateMask: { fieldPaths: Object.keys(data) } });
        },
      };
      try {
        const result = await operation(tx);
        if (writes.length) {
          const response = await this.request(`${this.root}:commit`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ transaction: transactionId, writes }) });
          if (!response.ok) {
            if (response.status === 409 || response.status === ABORTED) {
              await this.rollback(transactionId);
              continue;
            }
            throw await firestoreError(response);
          }
        } else {
          await this.request(`${this.root}:rollback`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ transaction: transactionId }) });
        }
        return result;
      } catch (error) {
        await this.rollback(transactionId);
        if (error instanceof ApiError && error.status === 409 && attempt < 4) continue;
        throw error;
      }
    }
    throw new ApiError("unavailable", "Firestore transaction could not be completed after retries.");
  }

  private async request(url: string, init: RequestInit = {}): Promise<Response> {
    let response: Response;
    try {
      response = await this.fetcher(url, { ...init, headers: { ...(init.headers ?? {}), Authorization: `Bearer ${await this.auth.accessToken()}` } });
    } catch {
      throw new ApiError("unavailable", "Firestore is temporarily unavailable.");
    }
    return response;
  }
  private async rollback(transactionId: string): Promise<void> {
    try {
      await this.request(`${this.root}:rollback`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ transaction: transactionId }) });
    } catch { /* original operation or commit error is authoritative */ }
  }
}
function snapshot(exists: boolean, data?: Value): PairingSnapshot { return { exists, data: () => data }; }
const ABORTED = 409;
async function firestoreError(response: Response): Promise<ApiError> {
  const status = response.status;
  // Never forward raw upstream response bodies; they can contain request details.
  return new ApiError(status === 404 ? "not-found" : status === 403 ? "permission-denied" : status === 409 ? "unavailable" : status >= 500 ? "unavailable" : "internal", "Firestore request failed.");
}
