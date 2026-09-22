/**
 * Minimal structured logger.
 *
 * Only connection metadata is ever logged (device ids, socket ids, event
 * names, timestamps). Frame/payload contents are opaque Noise ciphertext
 * and are never logged, matching the relay's "dumb pipe" threat model.
 */

export type LogFields = Record<string, string | number | boolean | undefined>;

function write(level: "info" | "warn" | "error", event: string, fields: LogFields = {}): void {
  const entry = {
    ts: new Date().toISOString(),
    level,
    event,
    ...fields,
  };
  const line = JSON.stringify(entry);
  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

export const logger = {
  info: (event: string, fields?: LogFields) => write("info", event, fields),
  warn: (event: string, fields?: LogFields) => write("warn", event, fields),
  error: (event: string, fields?: LogFields) => write("error", event, fields),
};
