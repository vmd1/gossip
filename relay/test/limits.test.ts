import { describe, expect, it } from "vitest";
import { BanList } from "../src/bans.js";
import { loadConfig } from "../src/config.js";
import { coarseIp, limitKeyForIp, TokenBucket, WindowCounter } from "../src/limits.js";
import { parseControl, versionAtLeast } from "../src/protocol.js";
import { decodeB64, leadingZeroBits } from "../src/crypto.js";

describe("limits", () => {
  it("token bucket refills over time and never partially consumes", () => {
    let t = 0;
    const b = new TokenBucket(10, 100, () => t);
    expect(b.tryTake(100)).toBe(true);
    expect(b.tryTake(1)).toBe(false);
    t = 1000;
    expect(b.tryTake(11)).toBe(false);
    expect(b.tryTake(10)).toBe(true);
  });

  it("window counter slides", () => {
    let t = 0;
    const w = new WindowCounter(2, 1000, () => t);
    expect(w.hit("a")).toBe(true);
    expect(w.hit("a")).toBe(true);
    expect(w.hit("a")).toBe(false);
    expect(w.hit("b")).toBe(true);
    t = 1001;
    expect(w.hit("a")).toBe(true);
    w.sweep();
  });

  it("window counter caps tracked keys", () => {
    const w = new WindowCounter(1, 1000, () => 0, 3);
    for (let i = 0; i < 10; i++) w.hit(String(i));
    expect(w.size).toBe(3);
  });

  it("collapses IPv6 to /64 and unwraps mapped IPv4", () => {
    expect(limitKeyForIp("1.2.3.4")).toBe("1.2.3.4");
    expect(limitKeyForIp("::ffff:1.2.3.4")).toBe("1.2.3.4");
    const a = limitKeyForIp("2001:db8:1:2:aaaa:bbbb:cccc:dddd");
    expect(a).toBe(limitKeyForIp("2001:0db8:0001:0002::1"));
    expect(a).not.toBe(limitKeyForIp("2001:db8:1:3::1"));
    expect(limitKeyForIp("::1")).toBe("v6:0000:0000:0000:0000");
    expect(coarseIp("1.2.3.4")).toBe("1.2.3.0/24");
    expect(coarseIp("2001:db8:1:2::1")).toBe("2001:0db8:0001::/48");
  });

  it("ban list honours expiry and reload", () => {
    let t = Date.parse("2030-01-01T00:00:00Z");
    const b = new BanList(() => t);
    b.load("# c\nkey ABCD 2030-06-01T00:00:00Z\nip 9.9.9.9\nip 2001:db8::1 2029-01-01T00:00:00Z\nbogus\n");
    expect(b.isKeyBanned("abcd")).toBe(true);
    expect(b.isIpBanned("9.9.9.9")).toBe(true);
    expect(b.isIpBanned("2001:db8::5")).toBe(false); // expired
    t = Date.parse("2031-01-01T00:00:00Z");
    expect(b.isKeyBanned("abcd")).toBe(false);
    b.load("");
    expect(b.isIpBanned("9.9.9.9")).toBe(false);
  });

  it("version comparison", () => {
    expect(versionAtLeast("2.0", "2.0")).toBe(true);
    expect(versionAtLeast("1.9", "2.0")).toBe(false);
    expect(versionAtLeast("10.0", "2.0")).toBe(true);
    expect(versionAtLeast("2.1.3", "2.1")).toBe(true);
    expect(versionAtLeast("abc", "2.0")).toBe(false);
  });

  it("config defaults and validation", () => {
    const c = loadConfig({});
    expect(c.maxFrameBytes).toBe(16 * 1024 * 1024 + 16);
    expect(c.powBits).toBe(16);
    expect(c.maxMembersPerTopic).toBe(16);
    expect(c.metricsPort).toBe(0);
    expect(c.metricsOnPublicPort).toBe(false);
    expect(() => loadConfig({ POW_BITS: "x" })).toThrow();
  });

  it("strict base64 and leading zero bits", () => {
    expect(decodeB64("AAAA", 3)).not.toBeNull();
    expect(decodeB64("AAAA", 2)).toBeNull();
    expect(decodeB64("AAA", 3)).toBeNull(); // unpadded
    expect(decodeB64("AA-_", 3)).toBeNull(); // url-safe
    expect(decodeB64(5, 3)).toBeNull();
    expect(leadingZeroBits(Buffer.from([0, 0x10]))).toBe(11);
  });

  it("parseControl rejects bad shapes", () => {
    expect(parseControl("nope").ok).toBe(false);
    expect(parseControl("[]").ok).toBe(false);
    expect(parseControl('{"type":"relay.join"}').ok).toBe(false);
  });
});
