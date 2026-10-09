/**
 * Topic hub. Devices of one mesh join one topic and exchange opaque binary
 * frames routed by a cleartext 8-byte route tag. See docs/plans/relay.md and
 * relay/README.md.
 */
import { existsSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { Duplex } from "node:stream";
import { randomBytes } from "node:crypto";
import { WebSocketServer, type WebSocket, type RawData } from "ws";
import { BanList } from "./bans.js";
import type { RelayConfig } from "./config.js";
import { FRAME_HEADER_BYTES } from "./config.js";
import {
  b64,
  checkPow,
  ctEqual,
  ed25519Verify,
  joinProof,
  joinSigningInput,
  publicKeyHash,
  routeTag,
} from "./crypto.js";
import { TokenBucket, WindowCounter, coarseIp, limitKeyForIp, type Clock } from "./limits.js";
import { logger, setLogLevel } from "./logger.js";
import { Metrics } from "./metrics.js";
import { parseControl, versionAtLeast, type ErrorCode, type JoinMessage } from "./protocol.js";

interface Conn {
  ws: WebSocket;
  ipKey: string;
  ipLog: string;
  nonce: Buffer;
  joined: boolean;
  failing: boolean;
  closed: boolean;
  keyHex: string;
  topicHex: string;
  tag: Buffer;
  tagHex: string;
  joinAttempts: number;
  strikes: number;
  alive: boolean;
  lastActivity: number;
  lastErrorAt: number;
  handshakeTimer: NodeJS.Timeout | null;
  connBytes: TokenBucket;
  connFrames: TokenBucket;
  control: TokenBucket;
}

interface Topic {
  hex: string;
  verifier: Buffer;
  members: Map<string, Conn>;
  bucket: TokenBucket;
  day: number;
  bytesToday: number;
  emptySince: number | null;
}

export interface RelayOptions {
  now?: Clock;
}

export class Relay {
  readonly metrics = new Metrics();
  readonly httpServer: Server;
  readonly wss: WebSocketServer;
  metricsServer: Server | null = null;

  private readonly now: Clock;
  private readonly conns = new Set<Conn>();
  private readonly topics = new Map<string, Topic>();
  private readonly keyTopics = new Map<string, Set<string>>();
  private readonly known = new Map<string, number>();
  private readonly ipConns = new Map<string, number>();
  private readonly bans: BanList;
  private readonly newKeys: WindowCounter;
  private readonly newTopics: WindowCounter;
  private readonly connects: WindowCounter;
  private readonly timers: NodeJS.Timeout[] = [];
  private killManual: boolean;
  private killFile = false;

  constructor(readonly config: RelayConfig, opts: RelayOptions = {}) {
    this.now = opts.now ?? Date.now;
    setLogLevel(config.logLevel);
    this.killManual = config.killSwitch;
    this.bans = new BanList(this.now);
    this.newKeys = new WindowCounter(config.newKeysPerIpPerHour, 3_600_000, this.now);
    this.newTopics = new WindowCounter(config.newTopicsPerIpPerHour, 3_600_000, this.now);
    this.connects = new WindowCounter(config.connectsPerIpPerMinute, 60_000, this.now);

    this.httpServer = createServer((req, res) => this.handleHttp(req, res, false));
    this.httpServer.headersTimeout = 10_000;
    this.httpServer.requestTimeout = 10_000;
    this.httpServer.on("upgrade", (req, socket, head) => this.handleUpgrade(req, socket, head));
    this.httpServer.on("clientError", (_e, socket) => socket.destroy());
    this.wss = new WebSocketServer({ noServer: true, maxPayload: config.maxFrameBytes, perMessageDeflate: false });
    this.wss.on("error", (err) => logger.error("server.error", { message: err.message }));

    const m = this.metrics;
    m.gauge("relay_connections", () => this.conns.size);
    m.gauge("relay_topics", () => this.topics.size);
    m.gauge("relay_known_keys", () => this.known.size);
    m.gauge("relay_bans", () => this.bans.size);
    m.gauge("relay_kill_switch", () => (this.killed ? 1 : 0));
  }

  // ---- lifecycle -------------------------------------------------------

  async start(): Promise<void> {
    const c = this.config;
    if (c.banFile) {
      this.bans.loadFile(c.banFile);
      this.timers.push(setInterval(() => this.bans.loadFile(c.banFile), c.banReloadMs));
    }
    this.checkKillFile();
    if (c.killSwitchFile) this.timers.push(setInterval(() => this.checkKillFile(), 2000));
    if (c.pingIntervalMs > 0) this.timers.push(setInterval(() => this.heartbeat(), c.pingIntervalMs));
    this.timers.push(setInterval(() => this.sweep(), 30_000));
    for (const t of this.timers) t.unref();

    await new Promise<void>((resolve, reject) => {
      this.httpServer.once("error", reject);
      this.httpServer.listen(c.port, c.host, () => resolve());
    });
    if (c.metricsPort > 0) {
      this.metricsServer = createServer((req, res) => this.handleHttp(req, res, true));
      await new Promise<void>((resolve, reject) => {
        this.metricsServer!.once("error", reject);
        this.metricsServer!.listen(c.metricsPort, c.metricsHost, () => resolve());
      });
    }
  }

  get port(): number {
    const a = this.httpServer.address();
    return typeof a === "object" && a ? a.port : 0;
  }

  async close(): Promise<void> {
    for (const t of this.timers) clearInterval(t);
    this.timers.length = 0;
    for (const c of [...this.conns]) this.terminate(c);
    this.wss.close();
    await Promise.all(
      [this.httpServer, this.metricsServer].map(
        (s) =>
          new Promise<void>((resolve) => {
            if (!s || !s.listening) return resolve();
            s.close(() => resolve());
            s.closeAllConnections?.();
          }),
      ),
    );
  }

  // ---- kill switch -----------------------------------------------------

  get killed(): boolean {
    return this.killManual || this.killFile;
  }

  setKillSwitch(on: boolean): void {
    const was = this.killed;
    this.killManual = on;
    this.onKillChange(was);
  }

  toggleKillSwitch(): boolean {
    this.setKillSwitch(!this.killManual);
    return this.killManual;
  }

  private checkKillFile(): void {
    const f = this.config.killSwitchFile;
    if (!f) return;
    const was = this.killed;
    this.killFile = existsSync(f);
    this.onKillChange(was);
  }

  private onKillChange(was: boolean): void {
    if (this.killed && !was) {
      logger.warn("kill_switch.on", { connections: this.conns.size });
      for (const c of [...this.conns]) {
        this.sendError(c, "disabled");
        this.closeConn(c, 1012, "disabled");
      }
    } else if (!this.killed && was) {
      logger.warn("kill_switch.off");
    }
  }

  // ---- HTTP ------------------------------------------------------------

  private handleHttp(req: IncomingMessage, res: import("node:http").ServerResponse, onMetricsPort: boolean): void {
    const url = (req.url ?? "").split("?")[0];
    if (url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(this.killed ? "disabled" : "ok");
      return;
    }
    if (url === "/metrics" && (onMetricsPort || this.config.metricsOnPublicPort)) {
      const token = this.config.metricsToken;
      if (token && req.headers.authorization !== `Bearer ${token}`) {
        res.writeHead(401).end();
        return;
      }
      res.writeHead(200, { "content-type": "text/plain; version=0.0.4" });
      res.end(this.metrics.render());
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }

  private clientIp(req: IncomingMessage): string {
    const c = this.config;
    if (c.trustedProxy) {
      const raw = req.headers[c.trustedProxyHeader];
      const value = Array.isArray(raw) ? raw.join(",") : raw;
      if (value) {
        const list = value.split(",").map((s) => s.trim()).filter(Boolean);
        const idx = list.length - Math.max(1, c.trustedProxyHops);
        if (idx >= 0 && list[idx]) return list[idx]!;
      }
    }
    return req.socket.remoteAddress ?? "unknown";
  }

  private rejectUpgrade(socket: Duplex, status: string, reason: string, ip?: string): void {
    this.metrics.inc("relay_rejects_total", { reason });
    logger.info("upgrade.rejected", { reason, ip: ip ? coarseIp(ip) : undefined });
    socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    socket.destroy();
  }

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    socket.on("error", () => {});
    const c = this.config;
    if ((req.url ?? "").split("?")[0] !== c.path) return this.rejectUpgrade(socket, "404 Not Found", "bad_path");
    if (this.killed) return this.rejectUpgrade(socket, "503 Service Unavailable", "kill_switch");
    const ip = this.clientIp(req);
    const ipKey = limitKeyForIp(ip);
    if (this.bans.isIpBanned(ip)) return this.rejectUpgrade(socket, "403 Forbidden", "banned_ip", ip);
    if (!this.connects.hit(ipKey)) return this.rejectUpgrade(socket, "429 Too Many Requests", "connect_rate", ip);
    if ((this.ipConns.get(ipKey) ?? 0) >= c.maxConnectionsPerIp)
      return this.rejectUpgrade(socket, "429 Too Many Requests", "ip_connection_cap", ip);
    if (this.conns.size >= c.maxConnections)
      return this.rejectUpgrade(socket, "503 Service Unavailable", "max_connections", ip);
    this.wss.handleUpgrade(req, socket, head, (ws) => this.onConnection(ws, ip, ipKey));
  }

  // ---- connections -----------------------------------------------------

  private onConnection(ws: WebSocket, ip: string, ipKey: string): void {
    const c = this.config;
    const conn: Conn = {
      ws,
      ipKey,
      ipLog: coarseIp(ip),
      nonce: randomBytes(32),
      joined: false,
      failing: false,
      closed: false,
      keyHex: "",
      topicHex: "",
      tag: Buffer.alloc(0),
      tagHex: "",
      joinAttempts: 0,
      strikes: 0,
      alive: true,
      lastActivity: this.now(),
      lastErrorAt: 0,
      handshakeTimer: null,
      connBytes: new TokenBucket(c.connRateBytesPerSec, c.connBurstBytes, this.now),
      connFrames: new TokenBucket(c.connFramesPerSec, c.connFrameBurst, this.now),
      control: new TokenBucket(c.controlMsgsPerSec, c.controlBurst, this.now),
    };
    this.conns.add(conn);
    this.ipConns.set(ipKey, (this.ipConns.get(ipKey) ?? 0) + 1);
    this.metrics.inc("relay_connections_total");

    // Until joined, only small control messages are acceptable.
    this.setReceiverLimit(ws, c.maxControlBytes);

    ws.on("error", () => {});
    ws.on("pong", () => {
      conn.alive = true;
    });
    ws.on("close", () => this.onClose(conn));
    ws.on("message", (data, isBinary) => {
      try {
        this.onMessage(conn, data, isBinary);
      } catch (err) {
        logger.error("handler.exception", { message: (err as Error).message });
        this.metrics.inc("relay_handler_exceptions_total");
        this.closeConn(conn, 1011, "internal");
      }
    });

    conn.handshakeTimer = setTimeout(() => {
      if (!conn.joined) {
        this.metrics.inc("relay_rejects_total", { reason: "handshake_timeout" });
        this.closeConn(conn, 1008, "handshake timeout");
      }
    }, c.handshakeTimeoutMs);
    conn.handshakeTimer.unref();

    this.sendJson(conn, {
      type: "relay.challenge",
      nonce: b64(conn.nonce),
      powBits: c.powBits,
    });
  }

  private setReceiverLimit(ws: WebSocket, bytes: number): void {
    // ws exposes maxPayload only per server; tighten it per connection
    // while unauthenticated so pre-join peers cannot make us buffer 16 MiB.
    const receiver = (ws as unknown as { _receiver?: { _maxPayload: number } })._receiver;
    if (receiver) receiver._maxPayload = bytes;
  }

  private onClose(conn: Conn): void {
    if (conn.closed) return;
    conn.closed = true;
    if (conn.handshakeTimer) clearTimeout(conn.handshakeTimer);
    this.conns.delete(conn);
    const n = (this.ipConns.get(conn.ipKey) ?? 1) - 1;
    if (n <= 0) this.ipConns.delete(conn.ipKey);
    else this.ipConns.set(conn.ipKey, n);
    this.removeMember(conn);
  }

  private closeConn(conn: Conn, code: number, reason: string): void {
    try {
      conn.ws.close(code, reason);
    } catch {
      /* already closing */
    }
    // Do not wait on a peer that never answers the close handshake.
    const t = setTimeout(() => this.terminate(conn), 2000);
    t.unref();
    this.onClose(conn);
  }

  private terminate(conn: Conn): void {
    try {
      conn.ws.terminate();
    } catch {
      /* ignore */
    }
    this.onClose(conn);
  }

  private heartbeat(): void {
    const t = this.now();
    for (const conn of [...this.conns]) {
      if (!conn.alive) {
        this.metrics.inc("relay_rejects_total", { reason: "dead_peer" });
        this.terminate(conn);
        continue;
      }
      if (this.config.idleTimeoutMs > 0 && t - conn.lastActivity > this.config.idleTimeoutMs) {
        this.metrics.inc("relay_rejects_total", { reason: "idle_timeout" });
        this.closeConn(conn, 1001, "idle");
        continue;
      }
      conn.alive = false;
      try {
        conn.ws.ping();
      } catch {
        this.terminate(conn);
      }
    }
  }

  private sweep(): void {
    const t = this.now();
    for (const [hex, topic] of this.topics) {
      if (topic.members.size === 0 && topic.emptySince !== null && t - topic.emptySince > this.config.topicLingerMs) {
        this.topics.delete(hex);
      }
    }
    this.newKeys.sweep();
    this.newTopics.sweep();
    this.connects.sweep();
  }

  // ---- sending ---------------------------------------------------------

  private sendJson(conn: Conn, obj: unknown): void {
    if (conn.closed) return;
    try {
      conn.ws.send(JSON.stringify(obj));
    } catch {
      /* socket gone */
    }
  }

  private sendError(conn: Conn, code: ErrorCode): void {
    this.sendJson(conn, { type: "relay.error", code });
  }

  /** Error for rate-limited data frames, at most once per second per conn. */
  private throttledError(conn: Conn, code: ErrorCode): void {
    const t = this.now();
    if (t - conn.lastErrorAt < 1000) return;
    conn.lastErrorAt = t;
    this.sendError(conn, code);
  }

  // ---- receiving -------------------------------------------------------

  private onMessage(conn: Conn, data: RawData, isBinary: boolean): void {
    if (conn.closed || conn.failing) return;
    conn.lastActivity = this.now();
    const buf = toBuffer(data);

    if (isBinary && conn.joined) return this.onFrame(conn, buf);

    // Everything else is a control message and is rate limited as such.
    if (!conn.control.tryTake(1)) {
      this.metrics.inc("relay_rejects_total", { reason: "control_rate" });
      this.sendError(conn, "rate_limited");
      return this.closeConn(conn, 1008, "rate limited");
    }
    if (isBinary) {
      this.metrics.inc("relay_rejects_total", { reason: "not_joined" });
      this.sendError(conn, "not_joined");
      return this.closeConn(conn, 1008, "not joined");
    }
    if (buf.length > this.config.maxControlBytes) {
      this.metrics.inc("relay_rejects_total", { reason: "control_too_large" });
      return this.closeConn(conn, 1009, "too large");
    }
    if (conn.joined) {
      this.metrics.inc("relay_rejects_total", { reason: "already_joined" });
      this.sendError(conn, "already_joined");
      return this.closeConn(conn, 1008, "protocol");
    }
    const parsed = parseControl(buf.toString("utf8"));
    if (!parsed.ok) {
      this.metrics.inc("relay_rejects_total", { reason: "bad_request" });
      this.sendError(conn, parsed.code);
      return this.closeConn(conn, 1008, "bad request");
    }
    this.handleJoin(conn, parsed.join);
  }

  // ---- join ------------------------------------------------------------

  private reject(conn: Conn, code: ErrorCode, reason: string, keepOpen = false): void {
    this.metrics.inc("relay_rejects_total", { reason });
    logger.info("join.rejected", { reason, ip: conn.ipLog });
    this.sendError(conn, code);
    if (!keepOpen) this.closeConn(conn, 1008, "rejected");
  }

  /** Same code, same delay, whatever the underlying cause. */
  private rejectUniform(conn: Conn, reason: string, startedAt: number): void {
    this.metrics.inc("relay_rejects_total", { reason });
    logger.info("join.rejected", { reason, ip: conn.ipLog });
    conn.failing = true;
    const wait = Math.max(0, this.config.joinFailDelayMs - (Date.now() - startedAt));
    const t = setTimeout(() => {
      this.sendError(conn, "join_failed");
      this.closeConn(conn, 1008, "rejected");
    }, wait);
    t.unref();
  }

  private get overloaded(): boolean {
    const c = this.config;
    return this.conns.size >= c.shedRatio * c.maxConnections || this.topics.size >= c.shedRatio * c.maxTopics;
  }

  private handleJoin(conn: Conn, j: JoinMessage): void {
    const c = this.config;
    const started = Date.now();
    conn.joinAttempts++;

    if (this.killed) return this.reject(conn, "disabled", "kill_switch");
    if (!versionAtLeast(j.version, c.minClientVersion)) return this.reject(conn, "upgrade_required", "version");

    const keyHash = publicKeyHash(j.publicKey);
    const keyHex = keyHash.toString("hex");
    if (this.bans.isKeyBanned(keyHex)) return this.reject(conn, "denied", "banned_key");

    if (c.operatorSecret || c.allowedKeys.length > 0) {
      const okSecret = c.operatorSecret !== "" && ctEqual(Buffer.from(j.credential), Buffer.from(c.operatorSecret));
      const okKey = c.allowedKeys.includes(keyHex);
      if (!okSecret && !okKey) return this.reject(conn, "unauthorized", "operator_credential");
    }

    const signed = joinSigningInput(c.relayOrigin, conn.nonce, j.topicId);
    if (!ed25519Verify(j.publicKey, signed, j.sig)) return this.reject(conn, "auth_failed", "bad_signature");

    const isNewKey = !this.known.has(keyHex);
    if (isNewKey) {
      if (c.powBits > 0) {
        if (!j.pow) {
          if (conn.joinAttempts < c.maxJoinAttempts) return this.reject(conn, "pow_required", "pow_required", true);
          return this.reject(conn, "pow_required", "pow_required");
        }
        if (!checkPow(keyHash, conn.nonce, j.pow, c.powBits)) {
          if (conn.joinAttempts < c.maxJoinAttempts) return this.reject(conn, "pow_invalid", "pow_invalid", true);
          return this.reject(conn, "pow_invalid", "pow_invalid");
        }
      }
      if (!this.newKeys.allows(conn.ipKey)) return this.reject(conn, "rate_limited", "new_key_rate");
      if (this.overloaded) return this.reject(conn, "busy", "shed_new_key");
    }

    const topicHex = j.topicId.toString("hex");
    const tag = routeTag(j.topicId, keyHash);
    const tagHex = tag.toString("hex");
    let topic = this.topics.get(topicHex);

    // Constant work whether or not the topic exists.
    const proofOk = ctEqual(joinProof(j.verifier, conn.nonce), j.proof);
    const verifierOk = ctEqual(topic ? topic.verifier : j.verifier, j.verifier);
    const replacing = topic?.members.get(tagHex);
    const collision = !!replacing && replacing.keyHex !== keyHex;
    const full = !!topic && !replacing && topic.members.size >= c.maxMembersPerTopic;

    if (!proofOk) return this.rejectUniform(conn, "bad_proof", started);
    if (!verifierOk) return this.rejectUniform(conn, "bad_verifier", started);
    if (full) return this.rejectUniform(conn, "topic_full", started);
    if (collision) return this.rejectUniform(conn, "tag_collision", started);

    if (!topic) {
      if (this.overloaded || this.topics.size >= c.maxTopics) return this.rejectUniform(conn, "shed_new_topic", started);
      if (!this.newTopics.allows(conn.ipKey)) return this.rejectUniform(conn, "new_topic_rate", started);
    }

    const mine = this.keyTopics.get(keyHex);
    if (mine && !mine.has(topicHex) && mine.size >= c.maxTopicsPerKey)
      return this.reject(conn, "limit_exceeded", "topics_per_key");

    // ---- accepted ----
    if (isNewKey) {
      this.newKeys.record(conn.ipKey);
      this.known.set(keyHex, this.now());
      if (this.known.size > c.maxKnownKeys) {
        const oldest = this.known.keys().next().value;
        if (oldest !== undefined) this.known.delete(oldest);
      }
    } else {
      this.known.delete(keyHex);
      this.known.set(keyHex, this.now());
    }
    if (!topic) {
      this.newTopics.record(conn.ipKey);
      topic = {
        hex: topicHex,
        verifier: Buffer.from(j.verifier),
        members: new Map(),
        bucket: new TokenBucket(c.topicRateBytesPerSec, c.topicBurstBytes, this.now),
        day: Math.floor(this.now() / 86_400_000),
        bytesToday: 0,
        emptySince: null,
      };
      this.topics.set(topicHex, topic);
      this.metrics.inc("relay_topics_created_total");
    }
    if (replacing) {
      this.sendError(replacing, "limit_exceeded");
      this.closeConn(replacing, 4001, "replaced");
    }

    if (conn.handshakeTimer) clearTimeout(conn.handshakeTimer);
    conn.handshakeTimer = null;
    conn.joined = true;
    conn.keyHex = keyHex;
    conn.topicHex = topicHex;
    conn.tag = tag;
    conn.tagHex = tagHex;
    this.setReceiverLimit(conn.ws, c.maxFrameBytes);
    topic.emptySince = null;
    const others = [...topic.members.values()];
    topic.members.set(tagHex, conn);
    let kt = this.keyTopics.get(keyHex);
    if (!kt) this.keyTopics.set(keyHex, (kt = new Set()));
    kt.add(topicHex);
    this.metrics.inc("relay_joins_total");
    logger.info("join.ok", { ip: conn.ipLog, members: topic.members.size });

    this.sendJson(conn, {
      type: "relay.joined",
      routeTag: b64(tag),
      members: others.map((m) => b64(m.tag)),
      limits: {
        maxFrameBytes: c.maxFrameBytes,
        maxMembers: c.maxMembersPerTopic,
        topicRateBytesPerSec: c.topicRateBytesPerSec,
        topicBurstBytes: c.topicBurstBytes,
        topicDailyQuotaBytes: c.topicDailyQuotaBytes,
      },
    });
    for (const m of others) this.sendJson(m, { type: "relay.peer_joined", routeTag: b64(tag) });
  }

  private removeMember(conn: Conn): void {
    if (!conn.joined) return;
    conn.joined = false;
    const topic = this.topics.get(conn.topicHex);
    if (topic && topic.members.get(conn.tagHex) === conn) {
      topic.members.delete(conn.tagHex);
      for (const m of topic.members.values()) this.sendJson(m, { type: "relay.peer_left", routeTag: b64(conn.tag) });
      if (topic.members.size === 0) topic.emptySince = this.now();
    }
    // Only drop the per-key topic record if the key has no other live
    // connection to that topic (a replacing connection keeps it).
    if (!topic || topic.members.get(conn.tagHex) === undefined) {
      const kt = this.keyTopics.get(conn.keyHex);
      if (kt) {
        kt.delete(conn.topicHex);
        if (kt.size === 0) this.keyTopics.delete(conn.keyHex);
      }
    }
  }

  // ---- data frames -----------------------------------------------------

  private strike(conn: Conn): void {
    if (++conn.strikes >= this.config.maxStrikes) {
      this.metrics.inc("relay_rejects_total", { reason: "too_many_strikes" });
      this.closeConn(conn, 1008, "abuse");
    }
  }

  private drop(conn: Conn, reason: string, code?: ErrorCode): void {
    this.metrics.inc("relay_frames_dropped_total", { reason });
    if (code) this.throttledError(conn, code);
    this.strike(conn);
  }

  private onFrame(conn: Conn, buf: Buffer): void {
    const c = this.config;
    if (buf.length <= FRAME_HEADER_BYTES || buf.length > c.maxFrameBytes) return this.drop(conn, "bad_frame");
    const topic = this.topics.get(conn.topicHex);
    if (!topic) return;
    const dst = topic.members.get(buf.subarray(0, 8).toString("hex"));
    if (!conn.connFrames.tryTake(1)) return this.drop(conn, "conn_frame_rate", "rate_limited");
    if (!dst || dst === conn) return this.drop(conn, "unknown_dst");
    if (!conn.connBytes.tryTake(buf.length)) return this.drop(conn, "conn_byte_rate", "rate_limited");
    if (!topic.bucket.tryTake(buf.length)) return this.drop(conn, "topic_rate", "rate_limited");

    const day = Math.floor(this.now() / 86_400_000);
    if (day !== topic.day) {
      topic.day = day;
      topic.bytesToday = 0;
    }
    if (topic.bytesToday + buf.length > c.topicDailyQuotaBytes) {
      this.metrics.inc("relay_quota_hits_total");
      return this.drop(conn, "quota", "quota_exceeded");
    }

    if (dst.ws.bufferedAmount + buf.length > c.maxSendQueueBytes) {
      this.metrics.inc("relay_slow_consumers_total");
      this.drop(conn, "slow_consumer");
      logger.warn("slow_consumer.disconnect", { ip: dst.ipLog });
      this.closeConn(dst, 1008, "slow consumer");
      return;
    }

    topic.bytesToday += buf.length;
    conn.tag.copy(buf, 8); // authenticated sender's tag, never the claimed one
    dst.ws.send(buf, { binary: true }, () => {});
    this.metrics.inc("relay_frames_relayed_total");
    this.metrics.inc("relay_bytes_relayed_total", undefined, buf.length);
  }
}

export function toBuffer(data: RawData): Buffer {
  return Array.isArray(data) ? Buffer.concat(data) : Buffer.isBuffer(data) ? data : Buffer.from(data);
}
