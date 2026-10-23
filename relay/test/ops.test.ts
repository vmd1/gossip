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

  it("serves the abuse contact only when configured", async () => {
    relay = await startRelay();
    expect((await get(`http://127.0.0.1:${relay.port}/abuse`)).status).toBe(404);
    await relay.close();
    relay = await startRelay({ ABUSE_CONTACT: "abuse@example.test" });
    expect(await get(`http://127.0.0.1:${relay.port}/abuse`)).toEqual({ status: 200, body: "Report abuse of this relay to abuse@example.test\n" });
    expect((await get(`http://127.0.0.1:${relay.port}/.well-known/security.txt`)).body).toBe("Contact: mailto:abuse@example.test\n");
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

describe("website", () => {
  const makeSite = () => {
    const dir = mkdtempSync(pjoin(tmpdir(), "site-"));
    writeFileSync(pjoin(dir, "index.html"), "<!doctype html><title>Gossip</title>");
    writeFileSync(pjoin(dir, "style.css"), "body{}");
    writeFileSync(pjoin(dir, "secret.env"), "nope");
    writeFileSync(pjoin(dir, ".hidden.html"), "nope");
    return dir;
  };
  const fetchRaw = async (url: string, init: RequestInit = {}) => {
    const r = await fetch(url, init);
    return { status: r.status, type: r.headers.get("content-type"), csp: r.headers.get("content-security-policy"), etag: r.headers.get("etag"), body: await r.text() };
  };

  it("serves the site at the root with a strict policy, and keeps the relay endpoints", async () => {
    relay = await startRelay({ SITE_DIR: makeSite(), ABUSE_CONTACT: "abuse@example.test" });
    const base = `http://127.0.0.1:${relay.port}`;
    const root = await fetchRaw(`${base}/`);
    expect(root.status).toBe(200);
    expect(root.type).toBe("text/html; charset=utf-8");
    expect(root.body).toContain("<title>Gossip</title>");
    expect(root.csp).toContain("default-src 'none'");
    expect((await fetchRaw(`${base}/index.html`)).status).toBe(200);
    expect((await fetchRaw(`${base}/style.css`)).type).toBe("text/css; charset=utf-8");
    expect((await fetchRaw(`${base}/healthz`)).body).toBe("ok");
    expect((await fetchRaw(`${base}/abuse`)).body).toContain("abuse@example.test");
  });

  it("serves only listed web files: no traversal, no hidden or unknown types, no writes", async () => {
    relay = await startRelay({ SITE_DIR: makeSite() });
    const base = `http://127.0.0.1:${relay.port}`;
    for (const path of ["/secret.env", "/.hidden.html", "/../package.json", "/%2e%2e/package.json", "/style.css/x", "/nope", "/%zz"]) {
      expect((await fetchRaw(`${base}${path}`)).status, path).toBe(404);
    }
    expect((await fetchRaw(`${base}/`, { method: "POST", body: "x" })).status).toBe(404);
  });

  it("answers HEAD and conditional requests", async () => {
    relay = await startRelay({ SITE_DIR: makeSite() });
    const base = `http://127.0.0.1:${relay.port}`;
    const first = await fetchRaw(`${base}/`);
    expect((await fetchRaw(`${base}/`, { method: "HEAD" })).body).toBe("");
    expect((await fetchRaw(`${base}/`, { headers: { "if-none-match": first.etag! } })).status).toBe(304);
  });

  it("answers byte ranges, which Safari needs to play video", async () => {
    const dir = makeSite();
    writeFileSync(pjoin(dir, "clip.mp4"), "0123456789");
    relay = await startRelay({ SITE_DIR: dir });
    const url = `http://127.0.0.1:${relay.port}/clip.mp4`;
    const part = await fetch(url, { headers: { range: "bytes=2-5" } });
    expect(part.status).toBe(206);
    expect(part.headers.get("content-type")).toBe("video/mp4");
    expect(part.headers.get("content-range")).toBe("bytes 2-5/10");
    expect(await part.text()).toBe("2345");
    expect(await (await fetch(url, { headers: { range: "bytes=7-" } })).text()).toBe("789");
    expect(await (await fetch(url, { headers: { range: "bytes=-3" } })).text()).toBe("789");
    expect(await (await fetch(url, { headers: { range: "bytes=4-99" } })).text()).toBe("456789");
    expect((await fetch(url, { headers: { range: "bytes=10-" } })).status).toBe(416);
    const whole = await fetch(url, { headers: { range: "bytes=0-1,4-5" } });
    expect(whole.status).toBe(200);
    expect(await whole.text()).toBe("0123456789");
  });

  it("is off unless SITE_DIR is set, and refuses a directory without an index", async () => {
    relay = await startRelay();
    expect((await fetchRaw(`http://127.0.0.1:${relay.port}/`)).status).toBe(404);
    await relay.close();
    relay = null;
    await expect(startRelay({ SITE_DIR: mkdtempSync(pjoin(tmpdir(), "empty-")) })).rejects.toThrow(/index\.html/);
  });
});
