/** Small in-memory rate-limiting primitives. All take an injectable clock. */

export type Clock = () => number;

export class TokenBucket {
  private tokens: number;
  private last: number;
  constructor(
    private readonly ratePerSec: number,
    private readonly burst: number,
    private readonly now: Clock,
  ) {
    this.tokens = burst;
    this.last = now();
  }
  /** Consume `n` tokens if available; never partially consumes. */
  tryTake(n: number): boolean {
    const t = this.now();
    this.tokens = Math.min(this.burst, this.tokens + ((t - this.last) / 1000) * this.ratePerSec);
    this.last = t;
    if (n > this.tokens) return false;
    this.tokens -= n;
    return true;
  }
}

/** Sliding-window event counter per string key, with a hard cap on keys. */
export class WindowCounter {
  private readonly map = new Map<string, number[]>();
  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: Clock,
    private readonly maxKeys = 200_000,
  ) {}
  private prune(key: string): number[] {
    const cutoff = this.now() - this.windowMs;
    const arr = this.map.get(key) ?? [];
    let i = 0;
    while (i < arr.length && arr[i]! <= cutoff) i++;
    if (i > 0) arr.splice(0, i);
    return arr;
  }
  /** True if another event would still be within the limit (does not record). */
  allows(key: string): boolean {
    return this.prune(key).length < this.limit;
  }
  record(key: string): void {
    const arr = this.prune(key);
    arr.push(this.now());
    this.map.delete(key);
    this.map.set(key, arr);
    if (this.map.size > this.maxKeys) {
      const oldest = this.map.keys().next().value;
      if (oldest !== undefined) this.map.delete(oldest);
    }
  }
  /** Check-and-record. */
  hit(key: string): boolean {
    if (!this.allows(key)) return false;
    this.record(key);
    return true;
  }
  sweep(): void {
    for (const key of [...this.map.keys()]) {
      if (this.prune(key).length === 0) this.map.delete(key);
    }
  }
  get size(): number {
    return this.map.size;
  }
}

/**
 * Collapse a client address to the unit limits are applied to: the IPv4
 * address, or the /64 prefix for IPv6.
 */
export function limitKeyForIp(addr: string): string {
  let a = addr.trim();
  const zone = a.indexOf("%");
  if (zone >= 0) a = a.slice(0, zone);
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(a);
  if (mapped) return mapped[1]!;
  if (!a.includes(":")) return a;
  const groups = expandV6(a);
  if (!groups) return a;
  return "v6:" + groups.slice(0, 4).join(":");
}

function expandV6(a: string): string[] | null {
  const halves = a.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  let groups: string[];
  if (halves.length === 2) {
    const fill = 8 - head.length - tail.length;
    if (fill < 0) return null;
    groups = [...head, ...Array<string>(fill).fill("0"), ...tail];
  } else {
    groups = head;
  }
  if (groups.length !== 8) return null;
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/i.test(g))) return null;
  return groups.map((g) => g.toLowerCase().padStart(4, "0"));
}

/** Coarse form safe to log: v4 /24 or v6 /48. */
export function coarseIp(addr: string): string {
  const key = limitKeyForIp(addr);
  if (key.startsWith("v6:")) return key.split(":").slice(1, 4).join(":") + "::/48";
  const p = key.split(".");
  return p.length === 4 ? `${p[0]}.${p[1]}.${p[2]}.0/24` : "unknown";
}
