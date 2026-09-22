/**
 * End-to-end smoke test: starts a real relay server on an ephemeral local
 * port, connects two real `ws` clients with distinct fake Ed25519
 * keypairs, drives each through the challenge/response auth handshake,
 * has one request a bridge to the other's deviceId, then sends a raw
 * binary frame and confirms it arrives unmodified on the other side.
 *
 * Run with: npm run smoke-test
 */
import nacl from "tweetnacl";
import WebSocket from "ws";
import { createRelayServer } from "../src/relay.js";

function b64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

function fail(message: string): never {
  console.error(`SMOKE TEST FAILED: ${message}`);
  process.exit(1);
}

/**
 * Every inbound message on each socket is buffered from the moment the
 * WebSocket is constructed (not just from when a specific wait starts), so
 * a message that arrives before we get around to awaiting it (e.g. the
 * server's challenge, sent immediately on connect) is never lost to a race
 * between 'open' resolving and a listener being attached.
 */
interface Inbox {
  json: Record<string, unknown>[];
  binary: Buffer[];
  onAppend: Array<() => void>;
}

function attachInbox(ws: WebSocket): Inbox {
  const inbox: Inbox = { json: [], binary: [], onAppend: [] };
  ws.on("message", (data: Buffer, isBinary: boolean) => {
    if (isBinary) {
      inbox.binary.push(Buffer.from(data));
    } else {
      inbox.json.push(JSON.parse(data.toString("utf8")));
    }
    for (const cb of inbox.onAppend.splice(0)) cb();
  });
  return inbox;
}

async function waitForJson(
  inbox: Inbox,
  predicate: (msg: Record<string, unknown>) => boolean,
  timeoutMs = 3000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const idx = inbox.json.findIndex(predicate);
    if (idx !== -1) return inbox.json.splice(idx, 1)[0];
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("timed out waiting for expected message");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, remaining);
      inbox.onAppend.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
}

async function waitForBinary(inbox: Inbox, timeoutMs = 3000): Promise<Buffer> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (inbox.binary.length > 0) return inbox.binary.shift()!;
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("timed out waiting for binary frame");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, remaining);
      inbox.onAppend.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
}

async function main() {
  const { httpServer } = createRelayServer();
  await new Promise<void>((resolve) => httpServer.listen(0, resolve));
  const address = httpServer.address();
  if (typeof address !== "object" || address === null) {
    fail("server did not report a listening address");
  }
  const port = (address as { port: number }).port;
  const url = `ws://127.0.0.1:${port}/connect`;
  console.log(`relay listening at ${url}`);

  const aliceKeys = nacl.sign.keyPair();
  const bobKeys = nacl.sign.keyPair();
  const aliceDeviceId = "smoke-alice";
  const bobDeviceId = "smoke-bob";

  const alice = new WebSocket(url);
  const bob = new WebSocket(url);
  // Attach inboxes immediately so nothing sent right after connect is lost.
  const aliceInbox = attachInbox(alice);
  const bobInbox = attachInbox(bob);

  await Promise.all([
    new Promise((resolve) => alice.once("open", resolve)),
    new Promise((resolve) => bob.once("open", resolve)),
  ]);
  console.log("both clients connected");

  async function authenticate(
    ws: WebSocket,
    inbox: Inbox,
    deviceId: string,
    keys: nacl.SignKeyPair,
  ) {
    const challenge = await waitForJson(inbox, (m) => m.type === "relay.challenge");
    const nonce = challenge.nonce as string;
    const sig = nacl.sign.detached(Buffer.from(nonce, "base64"), keys.secretKey);
    ws.send(
      JSON.stringify({
        type: "relay.hello",
        deviceId,
        publicKeyB64: b64(keys.publicKey),
        nonceSignatureB64: b64(sig),
      }),
    );
    const welcome = await waitForJson(inbox, (m) => m.type === "relay.welcome");
    if (welcome.deviceId !== deviceId) {
      fail(`expected welcome for ${deviceId}, got ${JSON.stringify(welcome)}`);
    }
  }

  await authenticate(alice, aliceInbox, aliceDeviceId, aliceKeys);
  console.log("alice authenticated");
  await authenticate(bob, bobInbox, bobDeviceId, bobKeys);
  console.log("bob authenticated");

  alice.send(JSON.stringify({ type: "relay.connect", targetDeviceId: bobDeviceId }));
  bob.send(JSON.stringify({ type: "relay.connect", targetDeviceId: aliceDeviceId }));

  await Promise.all([
    waitForJson(aliceInbox, (m) => m.type === "relay.bridged"),
    waitForJson(bobInbox, (m) => m.type === "relay.bridged"),
  ]);
  console.log("bridge established between alice and bob");

  const payload = Buffer.from("opaque-noise-ciphertext-not-actually-encrypted-here", "utf8");
  const receivedPromise = waitForBinary(bobInbox);
  alice.send(payload, { binary: true });
  const received = await receivedPromise;

  if (!received.equals(payload)) {
    fail("binary frame received by bob did not match what alice sent");
  }
  console.log("binary frame relayed alice -> bob correctly, byte-for-byte");

  alice.close();
  bob.close();
  await new Promise<void>((resolve) => httpServer.close(() => resolve()));

  console.log("SMOKE TEST PASSED");
  process.exit(0);
}

main().catch((err) => {
  fail(err instanceof Error ? err.stack ?? err.message : String(err));
});
