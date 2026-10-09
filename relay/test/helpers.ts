import { randomBytes } from "node:crypto";
import WebSocket from "ws";
import { loadConfig, type RelayConfig } from "../src/config.js";
import { Relay } from "../src/hub.js";
import {
  b64,
  ed25519PublicFromSeed,
  ed25519Sign,
  joinProof,
  joinSigningInput,
  publicKeyHash,
  routeTag,
  solvePow,
  topicAuthKey,
  topicId,
  topicVerifier,
} from "../src/crypto.js";

export const ORIGIN = "wss://relay.test";

export const BASE_ENV: Record<string, string> = {
  PORT: "0",
  HOST: "127.0.0.1",
  RELAY_ORIGIN: ORIGIN,
  POW_BITS: "4",
  JOIN_FAIL_DELAY_MS: "30",
  LOG_LEVEL: "silent",
  // Generous by default; individual tests lower the limit they exercise.
  NEW_KEYS_PER_IP_HOUR: "10000",
  NEW_TOPICS_PER_IP_HOUR: "10000",
  CONNECTS_PER_IP_MINUTE: "100000",
  MAX_CONNECTIONS_PER_IP: "1000",
  MAX_TOPICS_PER_KEY: "100",
  CONN_FRAMES_PER_SEC: "100000",
  CONN_FRAME_BURST: "100000",
};

export async function startRelay(
  env: Record<string, string> = {},
  opts: { now?: () => number } = {},
): Promise<Relay> {
  const config: RelayConfig = loadConfig({ ...BASE_ENV, ...env });
  const relay = new Relay(config, opts);
  await relay.start();
  return relay;
}

export interface Device {
  seed: Buffer;
  publicKey: Buffer;
  keyHash: Buffer;
}
export function mkDevice(): Device {
  const seed = randomBytes(32);
  const publicKey = ed25519PublicFromSeed(seed);
  return { seed, publicKey, keyHash: publicKeyHash(publicKey) };
}

export interface Mesh {
  topicId: Buffer;
  verifier: Buffer;
}
export function mkMesh(secret: Buffer = randomBytes(32), epoch = 1): Mesh {
  return { topicId: topicId(secret, epoch), verifier: topicVerifier(topicAuthKey(secret, epoch)) };
}
export const tagOf = (mesh: Mesh, dev: Device): Buffer => routeTag(mesh.topicId, dev.keyHash);

export interface JoinOpts {
  origin?: string;
  version?: string;
  pow?: boolean | Buffer;
  credential?: string;
  nonce?: Buffer;
  proof?: Buffer;
  verifier?: Buffer;
  sig?: Buffer;
  publicKey?: Buffer;
}

type Msg = Record<string, unknown>;

export class TestClient {
  readonly ws: WebSocket;
  private msgs: Array<{ data: Buffer; binary: boolean }> = [];
  private waiters: Array<() => void> = [];
  closeCode: number | null = null;
  closed: Promise<number>;
  challenge: Msg | null = null;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.on("message", (data, binary) => {
      this.msgs.push({ data: data as Buffer, binary });
      this.waiters.splice(0).forEach((w) => w());
    });
    this.closed = new Promise((resolve) =>
      ws.on("close", (code) => {
        this.closeCode = code;
        this.waiters.splice(0).forEach((w) => w());
        resolve(code);
      }),
    );
    ws.on("error", () => {});
  }

  static async connect(relay: Relay, headers: Record<string, string> = {}): Promise<TestClient> {
    const ws = new WebSocket(`ws://127.0.0.1:${relay.port}${relay.config.path}`, { headers });
    const c = new TestClient(ws);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("unexpected-response", (_req, res) => reject(new Error(`http ${res.statusCode}`)));
      ws.once("error", (e) => reject(e));
    });
    return c;
  }

  private async next(binary: boolean | undefined, timeoutMs: number): Promise<Buffer | null> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const i = this.msgs.findIndex((m) => binary === undefined || m.binary === binary);
      if (i >= 0) return this.msgs.splice(i, 1)[0]!.data;
      const left = deadline - Date.now();
      if (left <= 0 || this.closeCode !== null) return null;
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  /** Next JSON control message, or null on timeout/close. */
  async json(timeoutMs = 2000): Promise<Msg | null> {
    const d = await this.next(false, timeoutMs);
    return d ? (JSON.parse(d.toString("utf8")) as Msg) : null;
  }
  async frame(timeoutMs = 2000): Promise<Buffer | null> {
    return this.next(true, timeoutMs);
  }
  async expectJson(type: string, timeoutMs = 2000): Promise<Msg> {
    const m = await this.json(timeoutMs);
    if (!m || m.type !== type) throw new Error(`expected ${type}, got ${JSON.stringify(m)}`);
    return m;
  }

  async getChallenge(): Promise<Msg> {
    if (!this.challenge) this.challenge = await this.expectJson("relay.challenge");
    return this.challenge;
  }

  async buildJoin(dev: Device, mesh: Mesh, o: JoinOpts = {}): Promise<Msg> {
    const ch = await this.getChallenge();
    const nonce = o.nonce ?? Buffer.from(ch.nonce as string, "base64");
    const sig =
      o.sig ?? ed25519Sign(dev.seed, joinSigningInput(o.origin ?? ORIGIN, nonce, mesh.topicId));
    const verifier = o.verifier ?? mesh.verifier;
    const msg: Msg = {
      type: "relay.join",
      publicKey: b64(o.publicKey ?? dev.publicKey),
      topicId: b64(mesh.topicId),
      sig: b64(sig),
      verifier: b64(verifier),
      proof: b64(o.proof ?? joinProof(verifier, nonce)),
      version: o.version ?? "2.0",
    };
    const bits = ch.powBits as number;
    if (o.pow instanceof Buffer) msg.pow = b64(o.pow);
    else if (o.pow !== false && bits > 0) msg.pow = b64(solvePow(dev.keyHash, nonce, bits));
    if (o.credential !== undefined) msg.credential = o.credential;
    return msg;
  }

  /** Send a join and return the first reply (joined or error). */
  async join(dev: Device, mesh: Mesh, o: JoinOpts = {}): Promise<Msg> {
    this.ws.send(JSON.stringify(await this.buildJoin(dev, mesh, o)));
    const r = await this.json();
    if (!r) throw new Error("no reply to join");
    return r;
  }

  sendFrame(dst: Buffer, src: Buffer, payload: Buffer): void {
    this.ws.send(Buffer.concat([dst, src, payload]));
  }

  close(): void {
    this.ws.close();
  }
}

export async function joined(relay: Relay, dev: Device, mesh: Mesh, o: JoinOpts = {}): Promise<TestClient> {
  const c = await TestClient.connect(relay);
  const r = await c.join(dev, mesh, o);
  if (r.type !== "relay.joined") throw new Error(`join failed: ${JSON.stringify(r)}`);
  return c;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function waitFor(cond: () => boolean, ms = 3000): Promise<void> {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error("waitFor timed out");
    await sleep(10);
  }
}
