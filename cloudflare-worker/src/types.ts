export interface Env {
  FIREBASE_PROJECT_ID: string;
  FIREBASE_WEB_API_KEY?: string;
  GOOGLE_SERVICE_ACCOUNT_JSON?: string;
  CORS_ALLOWED_ORIGINS?: string;
  MAX_REQUEST_BYTES?: string;
  ENVIRONMENT?: string;
}

export interface PairingSnapshot { readonly exists: boolean; data(): Record<string, unknown> | undefined; }
export interface PairingTransaction {
  get(ref: object): Promise<PairingSnapshot>;
  create(ref: object, data: Record<string, unknown>): void;
  update(ref: object, data: Record<string, unknown>): void;
}
export interface PairingStore {
  doc(collection: string, id: string): object;
  runTransaction<T>(operation: (transaction: PairingTransaction) => Promise<T>): Promise<T>;
}

export interface FirebaseIdClaims {
  iss: string;
  aud: string;
  sub: string;
  exp: number;
  iat: number;
  auth_time: number;
  [key: string]: unknown;
}

export interface FirebaseAccount {
  uid: string;
  disabled: boolean;
  validSinceSeconds: number;
  customClaims: Record<string, unknown>;
}

export interface AuthAdmin {
  getUser(uid: string): Promise<FirebaseAccount | null>;
  createUser(uid: string): Promise<FirebaseAccount>;
  updateUser(uid: string, update: {
    customClaims?: Record<string, unknown>;
    disabled?: boolean;
    revokeBeforeSeconds?: number;
  }): Promise<void>;
  createCustomToken(uid: string, claims: Record<string, unknown>): Promise<string>;
  assertActiveToken(uid: string, authTimeSeconds: number): Promise<void>;
}

export interface IdTokenVerifier {
  verify(token: string): Promise<FirebaseIdClaims>;
}

export interface Logger {
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
}

export interface MqttPublishTransport {
  publish(topic: string, payload: string, qos: 0 | 1 | 2, retain: boolean): Promise<void>;
}

export interface FirestoreReadStore {
  get(collection: string, id: string): Promise<Record<string, unknown> | undefined>;
  query(collection: string, structuredQuery: Record<string, unknown>): Promise<Array<{
    id: string;
    data: Record<string, unknown>;
  }>>;
}

export interface Dependencies {
  projectId: string;
  webApiKey?: string;
  verifier: IdTokenVerifier;
  auth: AuthAdmin;
  store: FirestoreReadStore & PairingStore;
  mqtt: MqttPublishTransport;
  logger: Logger;
  now(): Date;
  sleep(milliseconds: number): Promise<void>;
  randomBytes(length: number): Uint8Array;
}

export interface ExecutionContextLike {
  waitUntil(promise: Promise<unknown>): void;
}
