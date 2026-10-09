import { randomBytes } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import type { Relay } from "../src/hub.js";
import { parseControl } from "../src/protocol.js";
import { joined, mkDevice, mkMesh, sleep, startRelay, tagOf, TestClient } from "./helpers.js";

function prng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

let relay: Relay | null = null;
afterEach(async () => {
  await relay?.close();
  relay = null;
});

describe("fuzz", () => {
  it("parseControl never throws on random input or mutated joins", () => {
    const rnd = prng(1);
    const valid = JSON.stringify({
      type: "relay.join",
      publicKey: Buffer.alloc(32).toString("base64"),
      topicId: Buffer.alloc(32).toString("base64"),
      sig: Buffer.alloc(64).toString("base64"),
      verifier: Buffer.alloc(32).toString("base64"),
      proof: Buffer.alloc(32).toString("base64"),
      version: "2.0",
    });
    expect(parseControl(valid).ok).toBe(true);
    for (let i = 0; i < 20000; i++) {
      let s: string;
      const mode = i % 4;
      if (mode === 0) s = randomBytes(Math.floor(rnd() * 200)).toString("latin1");
      else if (mode === 1) s = valid.slice(0, Math.floor(rnd() * valid.length));
      else if (mode === 2) {
        const arr = valid.split("");
        for (let k = 0; k < 3; k++) arr[Math.floor(rnd() * arr.length)] = String.fromCharCode(Math.floor(rnd() * 128));
        s = arr.join("");
      } else {
        const o = JSON.parse(valid);
        const keys = Object.keys(o);
        o[keys[Math.floor(rnd() * keys.length)]!] = [null, 1, {}, [], "x", true, "A".repeat(100)][Math.floor(rnd() * 7)];
        s = JSON.stringify(o);
      }
      expect(() => parseControl(s)).not.toThrow();
    }
  });

  it("server survives random control messages and frames", async () => {
    relay = await startRelay({ CONTROL_BURST: "1000", CONTROL_MSGS_PER_SEC: "1000", MAX_STRIKES: "100000" });
    const rnd = prng(7);
    // Pre-join garbage on many short connections.
    for (let i = 0; i < 40; i++) {
      const c = await TestClient.connect(relay);
      const n = 1 + Math.floor(rnd() * 5);
      for (let k = 0; k < n; k++) {
        const len = Math.floor(rnd() * 300);
        const b = randomBytes(len);
        if (rnd() < 0.5) c.ws.send(b);
        else c.ws.send(b.toString("latin1"));
      }
      c.ws.terminate();
    }
    // Post-join garbage frames, including valid headers with random lengths.
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await joined(relay, a, mesh);
    const cb = await joined(relay, b, mesh);
    for (let i = 0; i < 500; i++) {
      const len = Math.floor(rnd() * 80);
      const buf = randomBytes(len);
      if (rnd() < 0.5 && len >= 8) tagOf(mesh, b).copy(buf, 0);
      ca.ws.send(buf);
      if (rnd() < 0.1) ca.ws.send(randomBytes(20).toString("hex"));
      if (ca.closeCode !== null) break;
    }
    await sleep(100);
    expect(relay.metrics.get("relay_handler_exceptions_total")).toBe(0);
    const health = await fetch(`http://127.0.0.1:${relay.port}/healthz`);
    expect(health.status).toBe(200);
    // A fresh pair still works.
    const m2 = mkMesh();
    const x = await joined(relay, mkDevice(), m2);
    const yDev = mkDevice();
    const y = await joined(relay, yDev, m2);
    await x.expectJson("relay.peer_joined");
    x.sendFrame(tagOf(m2, yDev), Buffer.alloc(8), Buffer.from("ok"));
    expect((await y.frame())!.subarray(16).toString()).toBe("ok");
    ca.ws.terminate();
    cb.ws.terminate();
  }, 20000);
});
