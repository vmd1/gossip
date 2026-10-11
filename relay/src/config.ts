/**
 * Single place where every tunable lives. Every value can be overridden by an
 * environment variable; defaults are starting values to tune against load
 * tests (see docs/plans/relay.md).
 */

export interface RelayConfig {
  host: string;
  port: number;
  path: string;
  /** Origin bound into the join signature, e.g. "wss://relay.example.com". */
  relayOrigin: string;

  // Frames
  maxFrameBytes: number;
  maxControlBytes: number;

  // Admission
  powBits: number;
  minClientVersion: string;
  operatorSecret: string;
  allowedKeys: string[]; // hex of publicKeyHash
  maxKnownKeys: number;
  maxMembersPerTopic: number;
  maxTopicsPerKey: number;
  newKeysPerIpPerHour: number;
  newTopicsPerIpPerHour: number;
  connectsPerIpPerMinute: number;
  maxJoinAttempts: number;
  joinFailDelayMs: number;
  topicLingerMs: number;

  // Throughput
  topicRateBytesPerSec: number;
  topicBurstBytes: number;
  topicDailyQuotaBytes: number;
  connRateBytesPerSec: number;
  connBurstBytes: number;
  connFramesPerSec: number;
  connFrameBurst: number;
  controlMsgsPerSec: number;
  controlBurst: number;
  maxStrikes: number;

  // Resources
  handshakeTimeoutMs: number;
  idleTimeoutMs: number;
  pingIntervalMs: number;
  maxSendQueueBytes: number;
  maxConnections: number;
  maxTopics: number;
  shedRatio: number;
  maxConnectionsPerIp: number;

  // Network / ops
  trustedProxy: boolean;
  trustedProxyHeader: string;
  trustedProxyHops: number;
  killSwitch: boolean;
  killSwitchFile: string;
  banFile: string;
  banReloadMs: number;
  metricsPort: number; // 0 = no separate metrics listener
  metricsHost: string;
  metricsOnPublicPort: boolean;
  metricsToken: string;
  logLevel: "info" | "warn" | "error" | "silent";
}

type Env = Record<string, string | undefined>;

function num(env: Env, name: string, def: number): number {
  const raw = env[name];
  if (raw === undefined || raw === "") return def;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) throw new Error(`invalid ${name}: ${raw}`);
  return n;
}
function bool(env: Env, name: string, def: boolean): boolean {
  const raw = env[name];
  if (raw === undefined || raw === "") return def;
  return ["1", "true", "yes", "on"].includes(raw.toLowerCase());
}
function str(env: Env, name: string, def: string): string {
  const raw = env[name];
  return raw === undefined ? def : raw;
}

export const MIB = 1024 * 1024;
export const FRAME_HEADER_BYTES = 16;

export function loadConfig(env: Env = process.env): RelayConfig {
  const port = num(env, "PORT", 8080);
  const level = str(env, "LOG_LEVEL", "info");
  return {
    host: str(env, "HOST", "0.0.0.0"),
    port,
    path: str(env, "RELAY_PATH", "/connect"),
    relayOrigin: str(env, "RELAY_ORIGIN", `ws://localhost:${port}`),

    maxFrameBytes: num(env, "MAX_FRAME_BYTES", 16 * MIB + FRAME_HEADER_BYTES),
    maxControlBytes: num(env, "MAX_CONTROL_BYTES", 2048),

    powBits: num(env, "POW_BITS", 16),
    minClientVersion: str(env, "MIN_CLIENT_VERSION", "0.0"),
    operatorSecret: str(env, "OPERATOR_SECRET", ""),
    allowedKeys: str(env, "ALLOWED_KEYS", "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
    maxKnownKeys: num(env, "MAX_KNOWN_KEYS", 200_000),
    maxMembersPerTopic: num(env, "TOPIC_MAX_MEMBERS", 16),
    maxTopicsPerKey: num(env, "MAX_TOPICS_PER_KEY", 4),
    newKeysPerIpPerHour: num(env, "NEW_KEYS_PER_IP_HOUR", 10),
    newTopicsPerIpPerHour: num(env, "NEW_TOPICS_PER_IP_HOUR", 10),
    connectsPerIpPerMinute: num(env, "CONNECTS_PER_IP_MINUTE", 60),
    maxJoinAttempts: num(env, "MAX_JOIN_ATTEMPTS", 3),
    joinFailDelayMs: num(env, "JOIN_FAIL_DELAY_MS", 100),
    topicLingerMs: num(env, "TOPIC_LINGER_MS", 10 * 60_000),

    topicRateBytesPerSec: num(env, "TOPIC_RATE_BYTES_PER_SEC", 1 * MIB),
    topicBurstBytes: num(env, "TOPIC_BURST_BYTES", 20 * MIB),
    topicDailyQuotaBytes: num(env, "TOPIC_DAILY_QUOTA_BYTES", 2 * 1024 * MIB),
    connRateBytesPerSec: num(env, "CONN_RATE_BYTES_PER_SEC", 1 * MIB),
    connBurstBytes: num(env, "CONN_BURST_BYTES", 20 * MIB),
    connFramesPerSec: num(env, "CONN_FRAMES_PER_SEC", 100),
    connFrameBurst: num(env, "CONN_FRAME_BURST", 200),
    controlMsgsPerSec: num(env, "CONTROL_MSGS_PER_SEC", 2),
    controlBurst: num(env, "CONTROL_BURST", 6),
    maxStrikes: num(env, "MAX_STRIKES", 200),

    handshakeTimeoutMs: num(env, "HANDSHAKE_TIMEOUT_MS", 10_000),
    idleTimeoutMs: num(env, "IDLE_TIMEOUT_MS", 3_600_000),
    pingIntervalMs: num(env, "PING_INTERVAL_MS", 30_000),
    maxSendQueueBytes: num(env, "MAX_SEND_QUEUE_BYTES", 32 * MIB),
    maxConnections: num(env, "MAX_CONNECTIONS", 10_000),
    maxTopics: num(env, "MAX_TOPICS", 5_000),
    shedRatio: num(env, "SHED_RATIO", 0.9),
    maxConnectionsPerIp: num(env, "MAX_CONNECTIONS_PER_IP", 20),

    trustedProxy: bool(env, "TRUSTED_PROXY", false),
    trustedProxyHeader: str(env, "TRUSTED_PROXY_HEADER", "x-forwarded-for").toLowerCase(),
    trustedProxyHops: num(env, "TRUSTED_PROXY_HOPS", 1),
    killSwitch: bool(env, "KILL_SWITCH", false),
    killSwitchFile: str(env, "KILL_SWITCH_FILE", ""),
    banFile: str(env, "BAN_FILE", ""),
    banReloadMs: num(env, "BAN_RELOAD_MS", 30_000),
    metricsPort: num(env, "METRICS_PORT", 0),
    metricsHost: str(env, "METRICS_HOST", "127.0.0.1"),
    metricsOnPublicPort: bool(env, "METRICS_PUBLIC", false),
    metricsToken: str(env, "METRICS_TOKEN", ""),
    logLevel: (["info", "warn", "error", "silent"].includes(level) ? level : "info") as RelayConfig["logLevel"],
  };
}
