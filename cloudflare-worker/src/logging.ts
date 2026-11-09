const secretKey = /(authorization|token|secret|password|private.?key|credential|api.?key|refresh)/i;
const tokenLike = /\b[A-Za-z0-9_-]{40,}\b/g;

export function redactFields(fields: Record<string, unknown> = {}): Record<string, unknown> {
  const safe: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) {
    if (secretKey.test(key)) {
      safe[key] = "[REDACTED]";
    } else if (typeof value === "string") {
      safe[key] = value.replace(tokenLike, "[REDACTED]").slice(0, 256);
    } else if (typeof value === "number" || typeof value === "boolean" || value === null) {
      safe[key] = value;
    } else {
      safe[key] = "[OMITTED]";
    }
  }
  return safe;
}

export function createLogger(write: (level: string, entry: Record<string, unknown>) => void) {
  return {
    info: (event: string, fields: Record<string, unknown> = {}) =>
      write("info", { event, ...redactFields(fields) }),
    warn: (event: string, fields: Record<string, unknown> = {}) =>
      write("warn", { event, ...redactFields(fields) }),
    error: (event: string, fields: Record<string, unknown> = {}) =>
      write("error", { event, ...redactFields(fields) }),
  };
}
