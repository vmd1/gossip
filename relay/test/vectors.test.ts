import { createHash, createHmac, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildVectors, VECTORS_PATH } from "../scripts/gen-vectors.js";
import { checkPow, leadingZeroBits } from "../src/crypto.js";

const onDisk = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
const sha = (...b: Buffer[]) => b.reduce((h, x) => h.update(x), createHash("sha256")).digest();
const hex = (s: string) => Buffer.from(s, "hex");

describe("relay conformance vectors", () => {
  it("file on disk matches the generator output exactly", () => {
    expect(JSON.parse(JSON.stringify(buildVectors()))).toEqual(onDisk);
  });

  it("topic derivation reproduces with plain node:crypto", () => {
    const secret = hex(onDisk.topicSecretHex);
    for (const t of onDisk.topics) {
      const epoch = Buffer.from(t.epochU64beHex, "hex");
      expect(BigInt(t.epoch)).toBe(epoch.readBigUInt64BE());
      const id = createHmac("sha256", secret).update("gossip-topic").update(epoch).digest();
      const ak = createHmac("sha256", secret).update("gossip-topic-auth").update(epoch).digest();
      expect(id.toString("hex")).toBe(t.topicIdHex);
      expect(ak.toString("hex")).toBe(t.topicAuthKeyHex);
      expect(sha(ak).toString("hex")).toBe(t.verifierHex);
      const [a, b] = onDisk.devices;
      expect(sha(id, hex(a.publicKeyHashHex)).subarray(0, 8).toString("hex")).toBe(t.routeTagAHex);
      expect(sha(id, hex(b.publicKeyHashHex)).subarray(0, 8).toString("hex")).toBe(t.routeTagBHex);
    }
  });

  it("join signature, proof and PoW verify independently", () => {
    const j = onDisk.join;
    const dev = onDisk.devices[0];
    const pub = Buffer.from(dev.publicKey, "base64");
    expect(sha(pub).toString("hex")).toBe(dev.publicKeyHashHex);
    const topic = onDisk.topics[0];
    const nonce = hex(j.nonceHex);
    const input = Buffer.concat([
      Buffer.from("gossip-relay-join-v1\n"),
      Buffer.from(onDisk.relayOrigin),
      Buffer.from([0x0a]),
      nonce,
      hex(topic.topicIdHex),
    ]);
    expect(input.toString("hex")).toBe(j.signingInputHex);
    const key = createPublicKey({
      key: Buffer.concat([hex("302a300506032b6570032100"), pub]),
      format: "der",
      type: "spki",
    });
    expect(verify(null, input, key, hex(j.sigHex))).toBe(true);
    expect(
      createHmac("sha256", hex(topic.verifierHex)).update(nonce).digest("hex"),
    ).toBe(j.proofHex);

    const digest = sha(Buffer.from("gossip-relay-pow-v1"), hex(dev.publicKeyHashHex), nonce, hex(j.powHex));
    expect(digest.toString("hex")).toBe(j.powDigestHex);
    expect(leadingZeroBits(digest)).toBeGreaterThanOrEqual(j.powBits);
    expect(checkPow(hex(dev.publicKeyHashHex), nonce, hex(j.powHex), j.powBits)).toBe(true);
    // Smallest solution: no lower counter works.
    for (let i = 0n; i < BigInt(j.powCounter); i += 997n) {
      const c = Buffer.alloc(8);
      c.writeBigUInt64BE(i);
      const d = sha(Buffer.from("gossip-relay-pow-v1"), hex(dev.publicKeyHashHex), nonce, c);
      if (i !== BigInt(j.powCounter)) expect(leadingZeroBits(d)).toBeLessThan(j.powBits + 8);
    }
  });

  it("join message fields are padded standard base64 of the right sizes", () => {
    const m = onDisk.join.joinMessage;
    const sizes: Record<string, number> = { publicKey: 32, topicId: 32, sig: 64, verifier: 32, proof: 32, pow: 8 };
    for (const [k, n] of Object.entries(sizes)) {
      const buf = Buffer.from(m[k], "base64");
      expect(buf.length).toBe(n);
      expect(buf.toString("base64")).toBe(m[k]);
    }
  });

  it("frame layout: dstTag || srcTag || payload with src rewritten", () => {
    const f = onDisk.frame;
    expect(f.sentFrameHex).toBe(f.dstTagHex + f.claimedSrcTagHex + f.payloadHex);
    expect(f.deliveredFrameHex).toBe(f.dstTagHex + onDisk.topics[0].routeTagAHex + f.payloadHex);
  });
});
