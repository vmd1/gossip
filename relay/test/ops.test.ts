import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join as pjoin } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Relay } from "../src/hub.js";
import { joined, mkDevice, mkMesh, sleep, startRelay, TestClient } from "./helpers.js";

let relay: Relay | null = null;
afterEach(async () => {
  await relay?.close();
  relay = null;
});

const get = async (url: string, headers: Record<string, string> = {}) => {
  const r = await fetch(url, { headers });
  return { status: r.status, body: await r.text() };
};
const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });

describe("kill switch", () => {
  it("runtime toggle disconnects members, refuses new connections, and recovers", async () => {
    relay = await startRelay();
    const c = await joined(relay, mkDevice(), mkMesh());
    relay.setKillSwitch(true);
    expect((await c.json())!.code).toBe("disabled");
    expect(await c.closed).toBe(1012);
    await expect(TestClient.connect(relay)).rejects.toThrow(/503/);
    expect((await get(`http://127.0.0.1:${relay.port}/healthz`)).body).toBe("disabled");
    expect(relay.toggleKillSwitch()).toBe(false);
    const c2 = await joined(relay, mkDevice(), mkMesh());
    c2.close();
  });

  it("env flag and kill file", async () => {
    relay = await startRelay({ KILL_SWITCH: "1" });
    await expect(TestClient.connect(relay)).rejects.toThrow(/503/);
    await relay.close();

    const file = pjoin(mkdtempSync(pjoin(tmpdir(), "kill-")), "KILL");
    writeFileSync(file, "");
    relay = await startRelay({ KILL_SWITCH_FILE: file });
    await expect(TestClient.connect(relay)).rejects.toThrow(/503/);
    expect(relay.killed).toBe(true);
  });
});

describe("ban list", () => {
  it("bans keys (with expiry) and IPs from a file", async () => {
    const banned = mkDevice();
    const expired = mkDevice();
    const dir = mkdtempSync(pjoin(tmpdir(), "ban-"));
    const file = pjoin(dir, "bans.txt");
    writeFileSync(
      file,
      `key ${banned.keyHash.toString("hex")} 2999-01-01T00:00:00Z\nkey ${expired.keyHash.toString("hex")} 2000-01-01T00:00:00Z\n`,
    );
    relay = await startRelay({ BAN_FILE: file });
    const c = await TestClient.connect(relay);
    expect((await c.join(banned, mkMesh())).code).toBe("denied");
    const c2 = await TestClient.connect(relay);
    expect((await c2.join(expired, mkMesh())).type).toBe("relay.joined");
    await relay.close();

    writeFileSync(file, "ip 127.0.0.1\n");
    relay = await startRelay({ BAN_FILE: file });
    await expect(TestClient.connect(relay)).rejects.toThrow(/403/);
  });
});

describe("health and metrics", () => {
  it("healthz is public; metrics are not served on the public port by default", async () => {
    relay = await startRelay();
    expect(await get(`http://127.0.0.1:${relay.port}/healthz`)).toEqual({ status: 200, body: "ok" });
    expect((await get(`http://127.0.0.1:${relay.port}/metrics`)).status).toBe(404);
  });

  it("metrics on a separate ops port", async () => {
    const mp = await freePort();
    relay = await startRelay({ METRICS_PORT: String(mp) });
    await joined(relay, mkDevice(), mkMesh());
    const c = await TestClient.connect(relay);
    await c.join(mkDevice(), mkMesh(), { version: "0.0.junk" }).catch(() => null);
    const { status, body } = await get(`http://127.0.0.1:${mp}/metrics`);
    expect(status).toBe(200);
    expect(body).toMatch(/relay_connections \d+/);
    expect(body).toMatch(/relay_topics 1/);
    expect(body).toMatch(/relay_joins_total 1/);
    expect(body).toMatch(/relay_bytes_relayed_total|relay_connections_total/);
  });

  it("metrics on the public port only when enabled, optionally with a token", async () => {
    relay = await startRelay({ METRICS_PUBLIC: "true", METRICS_TOKEN: "tok" });
    const url = `http://127.0.0.1:${relay.port}/metrics`;
    expect((await get(url)).status).toBe(401);
    expect((await get(url, { authorization: "Bearer tok" })).status).toBe(200);
  });

  it("counts rejects by reason", async () => {
    relay = await startRelay({ MIN_CLIENT_VERSION: "9.0" });
    const c = await TestClient.connect(relay);
    await c.join(mkDevice(), mkMesh());
    await sleep(10);
    expect(relay.metrics.render()).toContain('relay_rejects_total{reason="version"} 1');
  });
});
