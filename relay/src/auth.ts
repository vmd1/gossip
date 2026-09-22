import { randomBytes } from "node:crypto";
import nacl from "tweetnacl";

/** Number of random bytes used for the challenge nonce, before base64 encoding. */
export const NONCE_BYTES = 32;

/** Generates a fresh random challenge nonce, base64-encoded. */
export function generateNonce(): string {
  return randomBytes(NONCE_BYTES).toString("base64");
}

/**
 * Verifies that `signatureB64` is a valid Ed25519 signature over the raw
 * bytes of `nonceB64`, produced by the private key corresponding to
 * `publicKeyB64`.
 *
 * Returns false (never throws) for malformed base64, wrong-length keys, or
 * an invalid signature.
 */
export function verifyNonceSignature(
  nonceB64: string,
  publicKeyB64: string,
  signatureB64: string,
): boolean {
  try {
    const nonce = Buffer.from(nonceB64, "base64");
    const publicKey = Buffer.from(publicKeyB64, "base64");
    const signature = Buffer.from(signatureB64, "base64");

    if (publicKey.length !== nacl.sign.publicKeyLength) return false;
    if (signature.length !== nacl.sign.signatureLength) return false;
    if (nonce.length === 0) return false;

    return nacl.sign.detached.verify(nonce, signature, publicKey);
  } catch {
    return false;
  }
}
