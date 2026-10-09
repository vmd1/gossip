import { readFileSync } from "node:fs";
import { limitKeyForIp } from "./limits.js";

/**
 * Ban list file format, one entry per line (blank lines and # comments ok):
 *   key <hex SHA-256(publicKey)> [expiry ISO-8601]
 *   ip  <address or IPv6 address>  [expiry ISO-8601]
 * IPv6 entries ban the whole /64. Entries without an expiry are permanent.
 */
export class BanList {
  private keys = new Map<string, number>();
  private ips = new Map<string, number>();

  constructor(private readonly now: () => number) {}

  load(text: string): void {
    const keys = new Map<string, number>();
    const ips = new Map<string, number>();
    for (const raw of text.split("\n")) {
      const line = raw.replace(/#.*/, "").trim();
      if (!line) continue;
      const [kind, value, exp] = line.split(/\s+/);
      if (!kind || !value) continue;
      const expiry = exp ? Date.parse(exp) : Infinity;
      if (Number.isNaN(expiry)) continue;
      if (kind === "key") keys.set(value.toLowerCase(), expiry);
      else if (kind === "ip") ips.set(limitKeyForIp(value), expiry);
    }
    this.keys = keys;
    this.ips = ips;
  }

  loadFile(path: string): void {
    try {
      this.load(readFileSync(path, "utf8"));
    } catch {
      // Missing/unreadable file: keep the previous list.
    }
  }

  isKeyBanned(hashHex: string): boolean {
    const e = this.keys.get(hashHex);
    return e !== undefined && e > this.now();
  }
  isIpBanned(addr: string): boolean {
    const e = this.ips.get(limitKeyForIp(addr));
    return e !== undefined && e > this.now();
  }
  get size(): number {
    return this.keys.size + this.ips.size;
  }
}
