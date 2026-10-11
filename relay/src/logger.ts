/**
 * Minimal structured logger.
 *
 * Only coarse reasons and counters are logged: never payloads, route tags,
 * topic ids, key hashes or full client IPs (IPs are truncated to a /24 or
 * /48 by the caller via coarseIp).
 */

export type LogFields = Record<string, string | number | boolean | undefined>;
type Level = "info" | "warn" | "error";

let threshold: "info" | "warn" | "error" | "silent" = "info";
const rank = { info: 0, warn: 1, error: 2, silent: 3 } as const;

export function setLogLevel(level: "info" | "warn" | "error" | "silent"): void {
  threshold = level;
}

function write(level: Level, event: string, fields: LogFields = {}): void {
  if (rank[level] < rank[threshold]) return;
  const line = JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

export const logger = {
  info: (event: string, fields?: LogFields) => write("info", event, fields),
  warn: (event: string, fields?: LogFields) => write("warn", event, fields),
  error: (event: string, fields?: LogFields) => write("error", event, fields),
};
