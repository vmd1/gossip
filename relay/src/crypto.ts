/**
 * Relay-layer cryptography. Everything here is mirrored byte-for-byte by the
 * test vectors in schema/conformance/relay-vectors.json.
 */
import {
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  sign as edSign,
  timingSafeEqual,
  verify as edVerify,
} from "node:crypto";

const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

export const JOIN_DOMAIN = "gossip-relay-join-v1\n";
export const POW_DOMAIN = "gossip-relay-pow-v1";

export function sha256(...parts: Buffer[]): Buffer {
  const h = createHash("sha256");
  for (const p of parts) h.update(p);
  return h.digest();
}

export function hmac(key: Buffer, ...parts: Buffer[]): Buffer {
  const h = createHmac("sha256", key);
  for (const p of parts) h.update(p);
  return h.digest();
}

export function u64be(n: bigint | number): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
}

export function publicKeyHash(publicKey: Buffer): Buffer {
  return sha256(publicKey);
}

export function topicId(topicSecret: Buffer, epoch: bigint | number): Buffer {
  return hmac(topicSecret, Buffer.from("gossip-topic"), u64be(epoch));
}

export function topicAuthKey(topicSecret: Buffer, epoch: bigint | number): Buffer {
  return hmac(topicSecret, Buffer.from("gossip-topic-auth"), u64be(epoch));
}

/** What the relay stores for a topic: SHA-256(topicAuthKey). */
export function topicVerifier(authKey: Buffer): Buffer {
  return sha256(authKey);
}

export function routeTag(topic: Buffer, keyHash: Buffer): Buffer {
  return sha256(topic, keyHash).subarray(0, 8);
}

export function joinSigningInput(relayOrigin: string, nonce: Buffer, topic: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from(JOIN_DOMAIN, "utf8"),
    Buffer.from(relayOrigin, "utf8"),
    Buffer.from([0x0a]),
    nonce,
    topic,
  ]);
}

/**
 * The relay stores only SHA-256(topicAuthKey), so it cannot check an HMAC
 * keyed by topicAuthKey itself. The join therefore carries the verifier and
 * the proof is HMAC-SHA256(key = verifier, nonce): this binds the verifier to
 * this connection's fresh nonce.
 */
export function joinProof(verifier: Buffer, nonce: Buffer): Buffer {
  return hmac(verifier, nonce);
}

export function ed25519PublicFromSeed(seed: Buffer): Buffer {
  const priv = createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: "der", type: "pkcs8" });
  const der = createPublicKey(priv).export({ format: "der", type: "spki" }) as Buffer;
  return der.subarray(der.length - 32);
}

export function ed25519Sign(seed: Buffer, msg: Buffer): Buffer {
  const priv = createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: "der", type: "pkcs8" });
  return edSign(null, msg, priv);
}

export function ed25519Verify(publicKey: Buffer, msg: Buffer, sig: Buffer): boolean {
  try {
    const pub = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, publicKey]), format: "der", type: "spki" });
    return edVerify(null, msg, pub, sig);
  } catch {
    return false;
  }
}

export function ctEqual(a: Buffer, b: Buffer): boolean {
  if (a.length !== b.length) {
    // Still do a comparison of equal-length data to keep timing flat.
    timingSafeEqual(a, a);
    return false;
  }
  return timingSafeEqual(a, b);
}

export function leadingZeroBits(buf: Buffer): number {
  let bits = 0;
  for (const byte of buf) {
    if (byte === 0) {
      bits += 8;
      continue;
    }
    bits += Math.clz32(byte) - 24;
    break;
  }
  return bits;
}

export function powDigest(keyHash: Buffer, nonce: Buffer, pow: Buffer): Buffer {
  return sha256(Buffer.from(POW_DOMAIN, "utf8"), keyHash, nonce, pow);
}

export function checkPow(keyHash: Buffer, nonce: Buffer, pow: Buffer, bits: number): boolean {
  if (bits <= 0) return true;
  if (pow.length !== 8) return false;
  return leadingZeroBits(powDigest(keyHash, nonce, pow)) >= bits;
}

/** Smallest counter (as u64 big-endian) that satisfies the difficulty. */
export function solvePow(keyHash: Buffer, nonce: Buffer, bits: number, start = 0n): Buffer {
  if (bits <= 0) return u64be(0);
  for (let i = start; ; i++) {
    const pow = u64be(i);
    if (leadingZeroBits(powDigest(keyHash, nonce, pow)) >= bits) return pow;
  }
}

export function b64(buf: Buffer): string {
  return buf.toString("base64");
}

/** Strict standard padded base64 with an exact decoded length, else null. */
export function decodeB64(value: unknown, length: number): Buffer | null {
  if (typeof value !== "string") return null;
  if (value.length !== Math.ceil(length / 3) * 4) return null;
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return null;
  const buf = Buffer.from(value, "base64");
  if (buf.length !== length || buf.toString("base64") !== value) return null;
  return buf;
}
