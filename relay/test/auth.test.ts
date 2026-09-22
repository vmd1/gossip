import { describe, expect, it } from "vitest";
import nacl from "tweetnacl";
import { generateNonce, verifyNonceSignature } from "../src/auth.js";

function makeKeypair() {
  return nacl.sign.keyPair();
}

function sign(nonceB64: string, secretKey: Uint8Array): string {
  const nonceBytes = Buffer.from(nonceB64, "base64");
  const sig = nacl.sign.detached(nonceBytes, secretKey);
  return Buffer.from(sig).toString("base64");
}

describe("generateNonce", () => {
  it("produces distinct base64 nonces", () => {
    const a = generateNonce();
    const b = generateNonce();
    expect(a).not.toEqual(b);
    expect(Buffer.from(a, "base64").length).toBe(32);
  });
});

describe("verifyNonceSignature", () => {
  it("accepts a valid signature from the matching key", () => {
    const { publicKey, secretKey } = makeKeypair();
    const nonce = generateNonce();
    const sig = sign(nonce, secretKey);
    const publicKeyB64 = Buffer.from(publicKey).toString("base64");

    expect(verifyNonceSignature(nonce, publicKeyB64, sig)).toBe(true);
  });

  it("rejects a signature produced by a different key", () => {
    const signer = makeKeypair();
    const impostor = makeKeypair();
    const nonce = generateNonce();
    const sig = sign(nonce, signer.secretKey);
    const impostorPublicKeyB64 = Buffer.from(impostor.publicKey).toString("base64");

    expect(verifyNonceSignature(nonce, impostorPublicKeyB64, sig)).toBe(false);
  });

  it("rejects a signature over a different nonce than was signed", () => {
    const { publicKey, secretKey } = makeKeypair();
    const nonce = generateNonce();
    const otherNonce = generateNonce();
    const sig = sign(nonce, secretKey);
    const publicKeyB64 = Buffer.from(publicKey).toString("base64");

    expect(verifyNonceSignature(otherNonce, publicKeyB64, sig)).toBe(false);
  });

  it("rejects malformed base64 input without throwing", () => {
    expect(verifyNonceSignature("not-valid-base64!!", "also-bad", "still-bad")).toBe(false);
  });

  it("rejects a signature with the wrong length", () => {
    const { publicKey } = makeKeypair();
    const nonce = generateNonce();
    const publicKeyB64 = Buffer.from(publicKey).toString("base64");
    const badSig = Buffer.from("too-short").toString("base64");

    expect(verifyNonceSignature(nonce, publicKeyB64, badSig)).toBe(false);
  });

  it("rejects an empty nonce", () => {
    const { publicKey, secretKey } = makeKeypair();
    const sig = sign(generateNonce(), secretKey);
    const publicKeyB64 = Buffer.from(publicKey).toString("base64");
    expect(verifyNonceSignature("", publicKeyB64, sig)).toBe(false);
  });
});
