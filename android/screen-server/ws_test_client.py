#!/usr/bin/env python3
"""
Test viewer for the Android screen bridge (stdlib only). Not shipped — this is the "simple test
client" used to verify the Android side without the (not yet built) Mac viewer.

Usage (debug build installed, Shizuku running + granted, device on adb):
    ./ws_test_client.py [--seconds 5] [--out out.h264] [--power-test]

It sends the DEBUG_SCREEN_START broadcast, reads `screen.ready`'s port+token from logcat (the
app logs them only in debuggable builds), `adb forward`s the port, then plays viewer:
wrong token is rejected, correct token attaches, video is written to --out, optionally injects
POWER via the control channel, and finally sends DEBUG_SCREEN_STOP and checks the shell-UID
processes are gone.
"""
import argparse, base64, hashlib, json, os, re, socket, struct, subprocess, sys, time, uuid

def adb(*a, check=False):
    return subprocess.run(["adb", *a], capture_output=True, text=True, check=check).stdout

class WS:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /screen HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = self.s.recv(1)
            if not d: raise EOFError("closed during handshake")
            buf += d
        assert b" 101 " in buf.split(b"\r\n")[0], buf
        want = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert want in buf, "bad Sec-WebSocket-Accept"
    def _rd(self, n):
        b = b""
        while len(b) < n:
            d = self.s.recv(n - len(b))
            if not d: raise EOFError
            b += d
        return b
    def send(self, data, text=False):
        op = 1 if text else 2
        mask = os.urandom(4)
        n = len(data)
        hdr = bytes([0x80 | op])
        hdr += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
        self.s.sendall(hdr + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))
    def recv(self):
        """-> (kind, payload) kind in 'text','binary','close'; raises EOFError/timeout."""
        while True:
            b0, b1 = self._rd(2)
            op, n = b0 & 0xf, b1 & 0x7f
            if n == 126: n = struct.unpack(">H", self._rd(2))[0]
            elif n == 127: n = struct.unpack(">Q", self._rd(8))[0]
            p = self._rd(n)
            if op == 8: return "close", p
            if op == 9: continue
            return ("text" if op == 1 else "binary"), p

def wake():
    return adb("shell", "dumpsys power | grep -m1 mWakefulness=").strip()

def shell_procs():
    return [l for l in adb("shell", "ps -A").splitlines() if "app_process" in l and "shell" in l.split()[0]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=5)
    ap.add_argument("--out", default="bridge.h264")
    ap.add_argument("--power-test", action="store_true")
    a = ap.parse_args()

    sid = str(uuid.uuid4())
    adb("logcat", "-c")
    t0 = time.time()
    adb("shell", "am", "broadcast", "-a", "dev.vmd1.gossip.DEBUG_SCREEN_START", "--es", "sessionId", sid)
    port = token = None
    for _ in range(60):
        m = re.search(rf"READY sessionId={sid} port=(\d+) token=(\S+)", adb("logcat", "-d", "-s", "ScreenMirror"))
        if m: port, token = int(m[1]), m[2]; break
        time.sleep(0.5)
    if not port: sys.exit("FAIL: no screen.ready seen in logcat\n" + adb("logcat", "-d", "-s", "ScreenMirror", "ScrcpyServerSession"))
    print(f"screen.ready after {time.time()-t0:.1f}s: port={port} (token {len(token)} chars)")
    adb("forward", f"tcp:{port}", f"tcp:{port}")

    # 1. wrong token must be rejected
    bad = WS(port); bad.send(b"not-the-token", text=True)
    try: k, _ = bad.recv(); ok = k == "close"
    except (EOFError, ConnectionError, OSError): ok = True
    print("wrong token rejected:", ok); assert ok

    # 2. correct token attaches; header + video arrive
    ws = WS(port); ws.send(token.encode(), text=True)
    k, p = ws.recv(); hdr = json.loads(p); print("stream header:", hdr); assert k == "text"
    # 3. a second authenticated viewer must not get in (listener closes after the first)
    try:
        WS(port).send(token.encode(), text=True); second = False
    except (ConnectionError, OSError, EOFError): second = True
    print("second viewer refused:", second)

    video = bytearray(); n_pkt = key_frames = 0; sizes = []; first_video_at = None; ws.s.settimeout(2)
    if a.power_test: print("wakefulness before:", wake())
    end = time.time() + a.seconds; sent_power = False
    while time.time() < end:
        try: k, p = ws.recv()
        except socket.timeout: continue
        except EOFError: print("bridge closed the socket"); break
        if k != "binary": continue
        if p[0] == 0:
            flags = struct.unpack(">Q", p[1:9])[0]; video += p[9:]; n_pkt += 1
            key_frames += bool(flags & (1 << 61))
            first_video_at = first_video_at or time.time() - t0
        elif p[0] == 1: sizes.append(struct.unpack(">II", p[1:9]))
        if a.power_test and not sent_power:
            sent_power = True
            for act in (0, 1): ws.send(struct.pack(">BBIII", 0, act, 26, 0, 0)); time.sleep(0.05)
            time.sleep(1.5); print("wakefulness after POWER:", wake())
            for act in (0, 1): ws.send(struct.pack(">BBIII", 0, act, 26, 0, 0)); time.sleep(0.05)
            time.sleep(1.5); print("wakefulness after POWER #2:", wake())
    open(a.out, "wb").write(video)
    print(f"video: {n_pkt} packets, {len(video)} bytes, key frames={key_frames}, size msgs={sizes}, first video at +{first_video_at}s")

    # 4. stop: processes must go away
    ws.s.close()
    time.sleep(3)
    adb("shell", "am", "broadcast", "-a", "dev.vmd1.gossip.DEBUG_SCREEN_STOP", "--es", "sessionId", sid)
    time.sleep(2)
    left = shell_procs()
    print("leftover shell app_process after stop:", left or "none")
    adb("forward", "--remove", f"tcp:{port}")
    sys.exit(0 if (n_pkt > 0 and key_frames > 0 and not left) else 1)

if __name__ == "__main__":
    main()
