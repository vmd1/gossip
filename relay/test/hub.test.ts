import { randomBytes } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import type { Relay } from "../src/hub.js";
import { b64, joinProof, joinSigningInput, ed25519Sign, solvePow } from "../src/crypto.js";
import {
  joined,
  mkDevice,
  mkMesh,
  ORIGIN,
  sleep,
  startRelay,
  tagOf,
  TestClient,
  waitFor,
  type Device,
} from "./helpers.js";

let relay: Relay | null = null;
const clients: TestClient[] = [];
async function start(env: Record<string, string> = {}, opts: { now?: () => number } = {}) {
  relay = await startRelay(env, opts);
  return relay;
}
async function conn(r: Relay) {
  const c = await TestClient.connect(r);
  clients.push(c);
  return c;
}
async function join(r: Relay, dev: Device, mesh: ReturnType<typeof mkMesh>, o = {}) {
  const c = await joined(r, dev, mesh, o);
  clients.push(c);
  return c;
}
afterEach(async () => {
  for (const c of clients.splice(0)) {
    try {
      (c.ws as unknown as { _socket?: { resume(): void } })._socket?.resume();
      c.ws.terminate();
    } catch {
      /* ignore */
    }
  }
  await relay?.close();
  relay = null;
});

describe("happy path", () => {
  it("two clients join, see each other, exchange frames; srcTag is overwritten", async () => {
    const r = await start();
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await conn(r);
    const ja = await ca.join(a, mesh);
    expect(ja.type).toBe("relay.joined");
    expect(ja.members).toEqual([]);
    expect(ja.routeTag).toBe(b64(tagOf(mesh, a)));
    expect((ja.limits as Record<string, number>).maxMembers).toBe(16);

    const cb = await conn(r);
    const jb = await cb.join(b, mesh);
    expect(jb.members).toEqual([b64(tagOf(mesh, a))]);
    const pj = await ca.expectJson("relay.peer_joined");
    expect(pj.routeTag).toBe(b64(tagOf(mesh, b)));

    const spoof = Buffer.from("0102030405060708", "hex");
    ca.sendFrame(tagOf(mesh, b), spoof, Buffer.from("hello"));
    const f = (await cb.frame())!;
    expect(f.subarray(0, 8)).toEqual(tagOf(mesh, b));
    expect(f.subarray(8, 16)).toEqual(tagOf(mesh, a)); // not the spoofed tag
    expect(f.subarray(16).toString()).toBe("hello");

    cb.sendFrame(tagOf(mesh, a), tagOf(mesh, a), Buffer.from("back"));
    expect((await ca.frame())!.subarray(16).toString()).toBe("back");

    cb.close();
    const pl = await ca.expectJson("relay.peer_left");
    expect(pl.routeTag).toBe(b64(tagOf(mesh, b)));
  });

  it("carries a maximum-size frame", async () => {
    const r = await start({ TOPIC_BURST_BYTES: String(40 * 1024 * 1024), CONN_BURST_BYTES: String(40 * 1024 * 1024) });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    const payload = randomBytes(16 * 1024 * 1024);
    ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), payload);
    const f = (await cb.frame(10000))!;
    expect(f.length).toBe(16 * 1024 * 1024 + 16);
    expect(f.subarray(16).equals(payload)).toBe(true);
  });

  it("routes unicast only and never across topics", async () => {
    const r = await start();
    const m1 = mkMesh();
    const m2 = mkMesh();
    const [a, b, c, d] = [mkDevice(), mkDevice(), mkDevice(), mkDevice()];
    const ca = await join(r, a, m1);
    const cb = await join(r, b, m1);
    const cc = await join(r, c, m1);
    const cd = await join(r, d, m2);
    ca.sendFrame(tagOf(m1, b), Buffer.alloc(8), Buffer.from("x"));
    expect(await cb.frame()).not.toBeNull();
    expect(await cc.frame(150)).toBeNull();
    // Addressing a member of another topic goes nowhere.
    ca.sendFrame(tagOf(m2, d), Buffer.alloc(8), Buffer.from("x"));
    expect(await cd.frame(150)).toBeNull();
    expect(r.metrics.get("relay_frames_dropped_total", { reason: "unknown_dst" })).toBeGreaterThan(0);
  });

  it("reconnect of the same key replaces the old connection", async () => {
    const r = await start();
    const mesh = mkMesh();
    const a = mkDevice();
    const c1 = await join(r, a, mesh);
    const c2 = await join(r, a, mesh);
    expect(await c1.closed).toBe(4001);
    expect(c2.ws.readyState).toBe(c2.ws.OPEN);
  });
});

describe("authentication", () => {
  it("rejects a bad signature, other origin, replayed signature, wrong key", async () => {
    const r = await start();
    const mesh = mkMesh();
    const a = mkDevice();
    let c = await conn(r);
    expect((await c.join(a, mesh, { origin: "wss://evil.example" })).code).toBe("auth_failed");
    await c.closed;

    // Replay: take a valid signature from connection 1 and use it on connection 2.
    const c1 = await conn(r);
    const m1 = await c1.buildJoin(a, mesh);
    const c2 = await conn(r);
    const m2 = await c2.buildJoin(a, mesh);
    expect(m1.sig).not.toBe(m2.sig);
    c2.ws.send(JSON.stringify({ ...m2, sig: m1.sig }));
    expect(((await c2.json())!).code).toBe("auth_failed");

    // Spoofed identity: someone else's public key, own signature.
    const victim = mkDevice();
    c = await conn(r);
    expect((await c.join(a, mesh, { publicKey: victim.publicKey })).code).toBe("auth_failed");
    // Garbage signature.
    c = await conn(r);
    expect((await c.join(a, mesh, { sig: randomBytes(64) })).code).toBe("auth_failed");
    expect(r.metrics.get("relay_rejects_total", { reason: "bad_signature" })).toBe(4);
  });

  it("does not accept a second join or a binary frame before joining", async () => {
    const r = await start();
    const mesh = mkMesh();
    const c = await conn(r);
    await c.getChallenge();
    c.ws.send(randomBytes(40));
    expect((await c.json())!.code).toBe("not_joined");
    await c.closed;
    const d = await join(r, mkDevice(), mesh);
    d.ws.send(JSON.stringify({ type: "relay.join" }));
    expect((await d.json())!.code).toBe("already_joined");
  });

  it("uses uniform code and timing for bad proof, wrong verifier and full topic", async () => {
    const r = await start({ TOPIC_MAX_MEMBERS: "2", JOIN_FAIL_DELAY_MS: "80" });
    const mesh = mkMesh();
    await join(r, mkDevice(), mesh);
    await join(r, mkDevice(), mesh);

    const timed = async (o: Record<string, unknown>, m = mesh) => {
      const c = await conn(r);
      const t = Date.now();
      const reply = await c.join(mkDevice(), m, o);
      return { code: reply.code, ms: Date.now() - t };
    };
    const wrongVerifier = await timed({ verifier: randomBytes(32) }); // wrong secret
    const full = await timed({}); // correct proof, topic full
    const badProof = await timed({ proof: randomBytes(32) });
    for (const x of [wrongVerifier, full, badProof]) {
      expect(x.code).toBe("join_failed");
      expect(x.ms).toBeGreaterThanOrEqual(70);
    }
    expect(r.metrics.get("relay_rejects_total", { reason: "topic_full" })).toBe(1);
  });

  it("a later joiner with a different topic secret cannot enter an existing topic", async () => {
    const r = await start();
    const mesh = mkMesh();
    await join(r, mkDevice(), mesh);
    const impostor = { topicId: mesh.topicId, verifier: mkMesh().verifier };
    const c = await conn(r);
    expect((await c.join(mkDevice(), impostor)).code).toBe("join_failed");
  });
});

describe("proof of work", () => {
  it("requires PoW for a new key, keeps the socket open for a retry, then waives it", async () => {
    const r = await start({ POW_BITS: "8" });
    const mesh = mkMesh();
    const a = mkDevice();
    const c = await conn(r);
    expect((await c.join(a, mesh, { pow: false })).code).toBe("pow_required");
    expect((await c.join(a, mesh, { pow: Buffer.alloc(8, 0xff) })).code).toBe("pow_invalid");
    const ch = await c.getChallenge();
    expect(ch.powBits).toBe(8);
    const ok = await c.join(a, mesh); // solved
    expect(ok.type).toBe("relay.joined");

    // Known key: no PoW needed on a new connection / other topic.
    const c2 = await conn(r);
    expect((await c2.join(a, mkMesh(), { pow: false })).type).toBe("relay.joined");
    // A different, new key still needs it.
    const c3 = await conn(r);
    expect((await c3.join(mkDevice(), mesh, { pow: false })).code).toBe("pow_required");
  });

  it("PoW is bound to the connection nonce", async () => {
    const r = await start({ POW_BITS: "10" });
    const a = mkDevice();
    const c1 = await conn(r);
    const n1 = Buffer.from((await c1.getChallenge()).nonce as string, "base64");
    const pow = solvePow(a.keyHash, n1, 10);
    const c2 = await conn(r);
    expect((await c2.join(a, mkMesh(), { pow })).code).toBe("pow_invalid");
  });

  it("POW_BITS=0 disables it", async () => {
    const r = await start({ POW_BITS: "0" });
    const c = await conn(r);
    expect((await c.join(mkDevice(), mkMesh(), { pow: false })).type).toBe("relay.joined");
  });

  it("closes after too many failed attempts", async () => {
    const r = await start({ POW_BITS: "8", MAX_JOIN_ATTEMPTS: "2" });
    const c = await conn(r);
    const a = mkDevice();
    expect((await c.join(a, mkMesh(), { pow: false })).code).toBe("pow_required");
    expect((await c.join(a, mkMesh(), { pow: false })).code).toBe("pow_required");
    await c.closed;
  });
});

describe("admission limits", () => {
  it("limits new keys per IP", async () => {
    const r = await start({ NEW_KEYS_PER_IP_HOUR: "2" });
    await join(r, mkDevice(), mkMesh());
    await join(r, mkDevice(), mkMesh());
    const c = await conn(r);
    expect((await c.join(mkDevice(), mkMesh())).code).toBe("rate_limited");
    // A key the relay already knows is not limited.
    const known = mkDevice();
    const r2 = await start({ NEW_KEYS_PER_IP_HOUR: "1" });
    await join(r2, known, mkMesh());
    await join(r2, known, mkMesh());
  });

  it("limits new topics per IP uniformly (join_failed)", async () => {
    const r = await start({ NEW_TOPICS_PER_IP_HOUR: "2" });
    const a = mkDevice();
    await join(r, a, mkMesh());
    await join(r, a, mkMesh());
    const c = await conn(r);
    expect((await c.join(a, mkMesh())).code).toBe("join_failed");
    expect(r.metrics.get("relay_rejects_total", { reason: "new_topic_rate" })).toBe(1);
  });

  it("applies new-key limits per /64 for IPv6 behind a trusted proxy", async () => {
    const r = await start({ NEW_KEYS_PER_IP_HOUR: "2", TRUSTED_PROXY: "true" });
    const hdr = (ip: string) => ({ "x-forwarded-for": `6.6.6.6, ${ip}` });
    const j = async (ip: string) => {
      const c = await TestClient.connect(r, hdr(ip));
      clients.push(c);
      return c.join(mkDevice(), mkMesh());
    };
    expect((await j("2001:db8:1:2::1")).type).toBe("relay.joined");
    expect((await j("2001:db8:1:2:ffff::9")).type).toBe("relay.joined");
    expect((await j("2001:db8:1:2:1::3")).code).toBe("rate_limited");
    expect((await j("2001:db8:1:3::1")).type).toBe("relay.joined"); // other /64
  });

  it("ignores proxy headers unless configured", async () => {
    const r = await start({ NEW_KEYS_PER_IP_HOUR: "1" });
    const j = async (ip: string) => {
      const c = await TestClient.connect(r, { "x-forwarded-for": ip });
      clients.push(c);
      return c.join(mkDevice(), mkMesh());
    };
    expect((await j("1.1.1.1")).type).toBe("relay.joined");
    expect((await j("2.2.2.2")).code).toBe("rate_limited");
  });

  it("caps topic size", async () => {
    const r = await start({ TOPIC_MAX_MEMBERS: "3" });
    const mesh = mkMesh();
    for (let i = 0; i < 3; i++) await join(r, mkDevice(), mesh);
    const c = await conn(r);
    expect((await c.join(mkDevice(), mesh)).code).toBe("join_failed");
  });

  it("caps topics per key", async () => {
    const r = await start({ MAX_TOPICS_PER_KEY: "1" });
    const a = mkDevice();
    const first = await join(r, a, mkMesh());
    const c = await conn(r);
    expect((await c.join(a, mkMesh())).code).toBe("limit_exceeded");
    first.close();
    await first.closed;
    await sleep(30);
    const again = await conn(r);
    expect((await again.join(a, mkMesh())).type).toBe("relay.joined");
  });

  it("enforces operator secret or key allowlist", async () => {
    const a = mkDevice();
    const r = await start({ OPERATOR_SECRET: "s3cret" });
    let c = await conn(r);
    expect((await c.join(a, mkMesh())).code).toBe("unauthorized");
    c = await conn(r);
    expect((await c.join(a, mkMesh(), { credential: "wrong" })).code).toBe("unauthorized");
    c = await conn(r);
    expect((await c.join(a, mkMesh(), { credential: "s3cret" })).type).toBe("relay.joined");
    await r.close();

    const b = mkDevice();
    const r2 = await start({ ALLOWED_KEYS: b.keyHash.toString("hex").toUpperCase() });
    c = await conn(r2);
    expect((await c.join(a, mkMesh())).code).toBe("unauthorized");
    c = await conn(r2);
    expect((await c.join(b, mkMesh())).type).toBe("relay.joined");
  });

  it("version gate", async () => {
    const r = await start({ MIN_CLIENT_VERSION: "2.0" });
    let c = await conn(r);
    expect((await c.join(mkDevice(), mkMesh(), { version: "1.9" })).code).toBe("upgrade_required");
    c = await conn(r);
    expect((await c.join(mkDevice(), mkMesh(), { version: "junk" })).code).toBe("upgrade_required");
    c = await conn(r);
    expect((await c.join(mkDevice(), mkMesh(), { version: "2.1" })).type).toBe("relay.joined");
  });
});

describe("connection limits", () => {
  it("rate limits connection attempts per IP", async () => {
    const r = await start({ CONNECTS_PER_IP_MINUTE: "2" });
    await conn(r);
    await conn(r);
    await expect(TestClient.connect(r)).rejects.toThrow(/429/);
  });

  it("caps connections per IP", async () => {
    const r = await start({ MAX_CONNECTIONS_PER_IP: "2" });
    await conn(r);
    await conn(r);
    await expect(TestClient.connect(r)).rejects.toThrow(/429/);
  });

  it("caps total connections", async () => {
    const r = await start({ MAX_CONNECTIONS: "2" });
    await conn(r);
    await conn(r);
    await expect(TestClient.connect(r)).rejects.toThrow(/503/);
  });

  it("rejects the wrong path", async () => {
    const r = await start();
    const ws = new (await import("ws")).default(`ws://127.0.0.1:${r.port}/nope`);
    await new Promise<void>((res) => ws.on("error", () => res()));
  });

  it("closes a connection that never joins", async () => {
    const r = await start({ HANDSHAKE_TIMEOUT_MS: "100" });
    const c = await conn(r);
    expect(await c.closed).toBe(1008);
    expect(r.metrics.get("relay_rejects_total", { reason: "handshake_timeout" })).toBe(1);
  });

  it("closes an idle joined connection", async () => {
    const r = await start({ IDLE_TIMEOUT_MS: "120", PING_INTERVAL_MS: "40" });
    const c = await join(r, mkDevice(), mkMesh());
    expect(await c.closed).toBe(1001);
  });

  it("cuts off dead peers that do not answer pings", async () => {
    const r = await start({ PING_INTERVAL_MS: "40", IDLE_TIMEOUT_MS: "0" });
    const c = await join(r, mkDevice(), mkMesh());
    (c.ws as unknown as { _socket: { pause(): void } })._socket.pause();
    await waitFor(() => r.metrics.get("relay_rejects_total", { reason: "dead_peer" }) === 1);
  });

  it("rate limits control messages", async () => {
    const r = await start({ POW_BITS: "8", MAX_JOIN_ATTEMPTS: "50", CONTROL_BURST: "3", CONTROL_MSGS_PER_SEC: "1" });
    const c = await conn(r);
    const a = mkDevice();
    const mesh = mkMesh();
    for (let i = 0; i < 3; i++) expect((await c.join(a, mesh, { pow: false })).code).toBe("pow_required");
    c.ws.send(JSON.stringify(await c.buildJoin(a, mesh, { pow: false })));
    expect((await c.json())!.code).toBe("rate_limited");
    await c.closed;
  });

  it("rejects oversize frames and oversize pre-join messages", async () => {
    const r = await start({ MAX_FRAME_BYTES: "1000", MAX_CONTROL_BYTES: "512" });
    const c = await conn(r);
    c.ws.send("x".repeat(600));
    expect(await c.closed).toBe(1009);

    const d = await join(r, mkDevice(), mkMesh());
    d.ws.send(randomBytes(2000));
    expect(await d.closed).toBe(1009);
  });

  it("disconnects a slow consumer instead of buffering without limit", async () => {
    const r = await start({
      MAX_SEND_QUEUE_BYTES: "200000",
      TOPIC_RATE_BYTES_PER_SEC: "1000000000",
      TOPIC_BURST_BYTES: "1000000000",
      CONN_RATE_BYTES_PER_SEC: "1000000000",
      CONN_BURST_BYTES: "1000000000",
      TOPIC_DAILY_QUOTA_BYTES: "100000000000",
    });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    (cb.ws as unknown as { _socket: { pause(): void } })._socket.pause();
    const payload = randomBytes(256 * 1024);
    for (let i = 0; i < 400 && r.metrics.get("relay_slow_consumers_total") === 0; i++) {
      ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), payload);
      await sleep(5);
    }
    await waitFor(() => r.metrics.get("relay_slow_consumers_total") >= 1, 5000);
    // The sender is unaffected and is told the peer left.
    await ca.expectJson("relay.peer_left");
  }, 20000);
});

describe("throughput limits", () => {
  it("per-connection frame rate", async () => {
    const r = await start({ CONN_FRAME_BURST: "3", CONN_FRAMES_PER_SEC: "1" });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    for (let i = 0; i < 10; i++) ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.from("x"));
    await waitFor(() => r.metrics.get("relay_frames_dropped_total", { reason: "conn_frame_rate" }) >= 6);
    expect((await ca.json())!.code).toBe("rate_limited");
    let got = 0;
    while (await cb.frame(100)) got++;
    expect(got).toBe(3);
  });

  it("per-connection byte rate", async () => {
    const r = await start({ CONN_BURST_BYTES: "100", CONN_RATE_BYTES_PER_SEC: "0" });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.alloc(60)); // 76
    ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.alloc(60));
    expect(await cb.frame()).not.toBeNull();
    expect(await cb.frame(150)).toBeNull();
    expect(r.metrics.get("relay_frames_dropped_total", { reason: "conn_byte_rate" })).toBe(1);
  });

  it("per-topic token bucket", async () => {
    const r = await start({ TOPIC_BURST_BYTES: "100", TOPIC_RATE_BYTES_PER_SEC: "0" });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.alloc(60));
    ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.alloc(60));
    expect(await cb.frame()).not.toBeNull();
    expect(await cb.frame(150)).toBeNull();
    expect(r.metrics.get("relay_frames_dropped_total", { reason: "topic_rate" })).toBe(1);
    expect((await ca.json())!.code).toBe("rate_limited");
  });

  it("daily topic quota, reset at the UTC day boundary", async () => {
    let t = Date.UTC(2030, 0, 1, 12);
    const r = await start({ TOPIC_DAILY_QUOTA_BYTES: "200" }, { now: () => t });
    const mesh = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, mesh);
    const cb = await join(r, b, mesh);
    await ca.expectJson("relay.peer_joined");
    const send = () => ca.sendFrame(tagOf(mesh, b), Buffer.alloc(8), Buffer.alloc(84)); // 100 B
    send();
    send();
    send();
    expect(await cb.frame()).not.toBeNull();
    expect(await cb.frame()).not.toBeNull();
    expect(await cb.frame(150)).toBeNull();
    expect(r.metrics.get("relay_quota_hits_total")).toBe(1);
    expect((await ca.json())!.code).toBe("quota_exceeded");
    t += 24 * 3600 * 1000;
    send();
    expect(await cb.frame()).not.toBeNull();
  });

  it("drops short frames and closes after too many strikes", async () => {
    const r = await start({ MAX_STRIKES: "3" });
    const c = await join(r, mkDevice(), mkMesh());
    for (let i = 0; i < 3; i++) c.ws.send(Buffer.alloc(10));
    await c.closed;
    expect(r.metrics.get("relay_frames_dropped_total", { reason: "bad_frame" })).toBe(3);
  });
});

describe("load shedding", () => {
  it("sheds new topics and new keys first; existing meshes keep working", async () => {
    const r = await start({ MAX_TOPICS: "10", SHED_RATIO: "0.2" }); // sheds at 2 topics
    const m1 = mkMesh();
    const m2 = mkMesh();
    const [a, b] = [mkDevice(), mkDevice()];
    const ca = await join(r, a, m1);
    await join(r, mkDevice(), m2);

    // New topic refused (uniform code).
    let c = await conn(r);
    expect((await c.join(a, mkMesh())).code).toBe("join_failed");
    // Brand-new key refused with a retry-later code.
    c = await conn(r);
    expect((await c.join(mkDevice(), m1)).code).toBe("busy");
    // Existing member of an existing mesh can still join and talk.
    const cb = await join(r, b, m1).catch(() => null);
    expect(cb).toBeNull(); // b is a new key -> busy
    const a2 = await join(r, a, m1);
    expect(await ca.closed).toBe(4001);
    expect(a2.ws.readyState).toBe(a2.ws.OPEN);
    expect(r.metrics.get("relay_rejects_total", { reason: "shed_new_topic" })).toBe(1);
    expect(r.metrics.get("relay_rejects_total", { reason: "shed_new_key" })).toBeGreaterThanOrEqual(1);
  });

  it("hard topic cap", async () => {
    const r = await start({ MAX_TOPICS: "1", SHED_RATIO: "1" });
    const a = mkDevice();
    await join(r, a, mkMesh());
    const c = await conn(r);
    expect((await c.join(a, mkMesh())).code).toBe("join_failed");
  });
});

describe("misc", () => {
  it("never sends plaintext errors that distinguish an unknown topic from a wrong one", async () => {
    const r = await start();
    const c = await conn(r);
    // Unknown topic simply creates it; there is no 'no such topic' response at all.
    const reply = await c.join(mkDevice(), mkMesh());
    expect(reply.type).toBe("relay.joined");
  });

  it("empty topics linger, so a squatter cannot take over the verifier", async () => {
    const r = await start();
    const mesh = mkMesh();
    const first = await join(r, mkDevice(), mesh);
    first.close();
    await first.closed;
    await sleep(30);
    const c = await conn(r);
    expect((await c.join(mkDevice(), { topicId: mesh.topicId, verifier: mkMesh().verifier })).code).toBe("join_failed");
  });

  it("builds join signatures exactly like the documented format", async () => {
    const r = await start();
    const c = await conn(r);
    const a = mkDevice();
    const mesh = mkMesh();
    const nonce = Buffer.from((await c.getChallenge()).nonce as string, "base64");
    const pow = solvePow(a.keyHash, nonce, 4);
    c.ws.send(
      JSON.stringify({
        type: "relay.join",
        publicKey: b64(a.publicKey),
        topicId: b64(mesh.topicId),
        sig: b64(ed25519Sign(a.seed, joinSigningInput(ORIGIN, nonce, mesh.topicId))),
        verifier: b64(mesh.verifier),
        proof: b64(joinProof(mesh.verifier, nonce)),
        version: "2.0",
        pow: b64(pow),
      }),
    );
    expect((await c.expectJson("relay.joined")).members).toEqual([]);
  });
});
