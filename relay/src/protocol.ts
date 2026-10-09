/** Control-message parsing and validation. Pure; never throws. */
import { decodeB64 } from "./crypto.js";

export type ErrorCode =
  | "bad_request"
  | "upgrade_required"
  | "unauthorized"
  | "auth_failed"
  | "pow_required"
  | "pow_invalid"
  | "join_failed"
  | "denied"
  | "rate_limited"
  | "limit_exceeded"
  | "quota_exceeded"
  | "busy"
  | "disabled"
  | "not_joined"
  | "already_joined";

export interface JoinMessage {
  publicKey: Buffer;
  topicId: Buffer;
  sig: Buffer;
  verifier: Buffer;
  proof: Buffer;
  version: string;
  pow: Buffer | null;
  credential: string;
}

export type ParseResult = { ok: true; join: JoinMessage } | { ok: false; code: ErrorCode };

export function parseControl(text: string): ParseResult {
  let obj: unknown;
  try {
    obj = JSON.parse(text);
  } catch {
    return { ok: false, code: "bad_request" };
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) return { ok: false, code: "bad_request" };
  const m = obj as Record<string, unknown>;
  if (m.type !== "relay.join") return { ok: false, code: "bad_request" };
  const publicKey = decodeB64(m.publicKey, 32);
  const topicId = decodeB64(m.topicId, 32);
  const sig = decodeB64(m.sig, 64);
  const verifier = decodeB64(m.verifier, 32);
  const proof = decodeB64(m.proof, 32);
  if (!publicKey || !topicId || !sig || !verifier || !proof) return { ok: false, code: "bad_request" };
  if (typeof m.version !== "string" || m.version.length > 32) return { ok: false, code: "bad_request" };
  let pow: Buffer | null = null;
  if (m.pow !== undefined && m.pow !== null) {
    pow = decodeB64(m.pow, 8);
    if (!pow) return { ok: false, code: "bad_request" };
  }
  let credential = "";
  if (m.credential !== undefined) {
    if (typeof m.credential !== "string" || m.credential.length > 256) return { ok: false, code: "bad_request" };
    credential = m.credential;
  }
  return { ok: true, join: { publicKey, topicId, sig, verifier, proof, version: m.version, pow, credential } };
}

/** Compare "MAJOR.MINOR[.x]" numerically; unparsable versions are lowest. */
export function versionAtLeast(version: string, min: string): boolean {
  const parse = (s: string): number[] | null => {
    if (!/^\d+(\.\d+){0,2}$/.test(s)) return null;
    return s.split(".").map(Number);
  };
  const v = parse(version);
  const m = parse(min);
  if (!m) return true;
  if (!v) return false;
  for (let i = 0; i < 3; i++) {
    const a = v[i] ?? 0;
    const b = m[i] ?? 0;
    if (a !== b) return a > b;
  }
  return true;
}
