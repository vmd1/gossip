import { describe, expect, it } from "vitest";
import nacl from "tweetnacl";
import { ConnectionManager } from "../src/connectionManager.js";
import { MockSocket } from "./mockSocket.js";

interface Identity {
  deviceId: string;
  publicKeyB64: string;
  secretKey: Uint8Array;
}

function makeIdentity(deviceId: string): Identity {
  const { publicKey, secretKey } = nacl.sign.keyPair();
  return { deviceId, publicKeyB64: Buffer.from(publicKey).toString("base64"), secretKey };
}

function connect(manager: ConnectionManager): MockSocket {
  const socket = new MockSocket();
  manager.registerConnection(socket);
  return socket;
}

function challengeNonce(socket: MockSocket): string {
  const challenge = socket.jsonMessagesOfType("relay.challenge");
  expect(challenge.length).toBe(1);
  return challenge[0].nonce as string;
}

function authenticate(manager: ConnectionManager, socket: MockSocket, identity: Identity): void {
  const nonce = challengeNonce(socket);
  const nonceBytes = Buffer.from(nonce, "base64");
  const sig = nacl.sign.detached(nonceBytes, identity.secretKey);
  socket.deliver(
    Buffer.from(
      JSON.stringify({
        type: "relay.hello",
        deviceId: identity.deviceId,
        publicKeyB64: identity.publicKeyB64,
        nonceSignatureB64: Buffer.from(sig).toString("base64"),
      }),
      "utf8",
    ),
    false,
  );
}

function requestConnect(socket: MockSocket, targetDeviceId: string): void {
  socket.deliver(
    Buffer.from(JSON.stringify({ type: "relay.connect", targetDeviceId }), "utf8"),
    false,
  );
}

describe("ConnectionManager auth handshake", () => {
  it("sends a challenge nonce on connect", () => {
    const manager = new ConnectionManager();
    const socket = connect(manager);
    expect(challengeNonce(socket).length).toBeGreaterThan(0);
  });

  it("authenticates a client with a valid signature and sends relay.welcome", () => {
    const manager = new ConnectionManager();
    const socket = connect(manager);
    const identity = makeIdentity("device-a");

    authenticate(manager, socket, identity);

    const welcome = socket.jsonMessagesOfType("relay.welcome");
    expect(welcome).toHaveLength(1);
    expect(welcome[0].deviceId).toBe("device-a");
    expect(socket.closed).toBe(false);
  });

  it("rejects and closes the socket on an invalid signature", () => {
    const manager = new ConnectionManager();
    const socket = connect(manager);
    const nonce = challengeNonce(socket);
    void nonce;

    socket.deliver(
      Buffer.from(
        JSON.stringify({
          type: "relay.hello",
          deviceId: "device-a",
          publicKeyB64: Buffer.from(nacl.sign.keyPair().publicKey).toString("base64"),
          nonceSignatureB64: Buffer.from("not-a-real-signature-bytes-here").toString("base64"),
        }),
        "utf8",
      ),
      false,
    );

    const errors = socket.jsonMessagesOfType("relay.error");
    expect(errors).toHaveLength(1);
    expect(errors[0].code).toBe("auth_failed");
    expect(socket.closed).toBe(true);
  });

  it("rejects a signature that is valid but over the wrong nonce (replay from another session)", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    const identity = makeIdentity("device-a");

    // Sign socketB's nonce, but present it to socketA's session.
    const nonceB = challengeNonce(socketB);
    const sig = nacl.sign.detached(Buffer.from(nonceB, "base64"), identity.secretKey);

    socketA.deliver(
      Buffer.from(
        JSON.stringify({
          type: "relay.hello",
          deviceId: identity.deviceId,
          publicKeyB64: identity.publicKeyB64,
          nonceSignatureB64: Buffer.from(sig).toString("base64"),
        }),
        "utf8",
      ),
      false,
    );

    expect(socketA.jsonMessagesOfType("relay.error")[0].code).toBe("auth_failed");
    expect(socketA.closed).toBe(true);
  });

  it("rejects relay.connect before authentication", () => {
    const manager = new ConnectionManager();
    const socket = connect(manager);
    requestConnect(socket, "some-target");

    const errors = socket.jsonMessagesOfType("relay.error");
    expect(errors).toHaveLength(1);
    expect(errors[0].code).toBe("auth_required");
  });
});

describe("ConnectionManager pairing and bridging", () => {
  it("bridges two clients once both request each other, and relays binary frames both ways", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    const alice = makeIdentity("alice");
    const bob = makeIdentity("bob");

    authenticate(manager, socketA, alice);
    authenticate(manager, socketB, bob);

    requestConnect(socketA, "bob");
    // Not bridged yet — only one side has requested.
    expect(socketA.jsonMessagesOfType("relay.bridged")).toHaveLength(0);
    expect(manager.isBridged("alice")).toBe(false);

    requestConnect(socketB, "alice");
    // Now both sides requested each other -> bridged.
    expect(manager.isBridged("alice")).toBe(true);
    expect(manager.isBridged("bob")).toBe(true);
    expect(socketA.jsonMessagesOfType("relay.bridged")).toHaveLength(1);
    expect(socketB.jsonMessagesOfType("relay.bridged")).toHaveLength(1);

    const frameFromAlice = Buffer.from([1, 2, 3, 4]);
    socketA.deliver(frameFromAlice, true);
    const binaryReceivedByB = socketB.sent.filter((m) => Buffer.isBuffer(m));
    expect(binaryReceivedByB).toHaveLength(1);
    expect(binaryReceivedByB[0]).toEqual(frameFromAlice);

    const frameFromBob = Buffer.from([9, 9, 9]);
    socketB.deliver(frameFromBob, true);
    const binaryReceivedByA = socketA.sent.filter((m) => Buffer.isBuffer(m));
    expect(binaryReceivedByA).toHaveLength(1);
    expect(binaryReceivedByA[0]).toEqual(frameFromBob);
  });

  it("bridges immediately if the target already has a matching pending request waiting", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    authenticate(manager, socketA, makeIdentity("alice"));
    authenticate(manager, socketB, makeIdentity("bob"));

    requestConnect(socketB, "alice");
    expect(manager.isBridged("alice")).toBe(false);

    requestConnect(socketA, "bob");
    expect(manager.isBridged("alice")).toBe(true);
    expect(manager.isBridged("bob")).toBe(true);
  });

  it("does not relay binary frames between unbridged clients", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    authenticate(manager, socketA, makeIdentity("alice"));
    authenticate(manager, socketB, makeIdentity("bob"));

    socketA.deliver(Buffer.from([1, 2, 3]), true);
    expect(socketB.sent.filter((m) => Buffer.isBuffer(m))).toHaveLength(0);
  });

  it("tears down the bridge and notifies the surviving peer on disconnect", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    authenticate(manager, socketA, makeIdentity("alice"));
    authenticate(manager, socketB, makeIdentity("bob"));
    requestConnect(socketA, "bob");
    requestConnect(socketB, "alice");
    expect(manager.isBridged("alice")).toBe(true);

    socketA.close();

    expect(manager.isBridged("bob")).toBe(false);
    // socketB's own socket is not closed just because its peer dropped.
    expect(socketB.closed).toBe(false);
    const notices = socketB.jsonMessagesOfType("relay.peer-disconnected");
    expect(notices).toHaveLength(1);
    expect(notices[0].targetDeviceId).toBe("alice");
  });

  it("rejects a relay.connect target of self", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    authenticate(manager, socketA, makeIdentity("alice"));
    requestConnect(socketA, "alice");

    const errors = socketA.jsonMessagesOfType("relay.error");
    expect(errors).toHaveLength(1);
    expect(errors[0].code).toBe("invalid_target");
  });

  it("a reconnecting device replaces its prior connection and tears down its old bridge", () => {
    const manager = new ConnectionManager();
    const socketA = connect(manager);
    const socketB = connect(manager);
    authenticate(manager, socketA, makeIdentity("alice"));
    authenticate(manager, socketB, makeIdentity("bob"));
    requestConnect(socketA, "bob");
    requestConnect(socketB, "alice");
    expect(manager.isBridged("alice")).toBe(true);

    // Alice reconnects with a new socket.
    const socketA2 = connect(manager);
    authenticate(manager, socketA2, makeIdentity("alice"));

    expect(socketA.closed).toBe(true);
    expect(manager.isBridged("bob")).toBe(false);
    expect(manager.onlineDeviceCount).toBe(2);
  });
});
