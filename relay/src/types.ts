/**
 * Shared types for the relay-layer JSON control protocol.
 *
 * This protocol lives entirely at the relay layer, outside of and prior to
 * the Noise session the two Connect clients establish with each other. The
 * relay never sees Noise plaintext or Noise handshake messages themselves —
 * it only relays opaque, already-encrypted binary frames once two clients
 * are bridged.
 *
 * Message flow:
 *   1. Client opens a WebSocket connection to the relay.
 *   2. Server -> Client: RelayChallenge (a random nonce to sign).
 *   3. Client -> Server: RelayHello (deviceId, Ed25519 public key, and a
 *      signature over the challenge nonce using the device's Ed25519
 *      identity private key).
 *   4. Server verifies the signature against the claimed public key. On
 *      success the connection is marked authenticated; on failure the
 *      socket is closed.
 *   5. Client -> Server: RelayConnect (targetDeviceId) to request being
 *      bridged to another authenticated, connected client.
 *   6. Once both sides have a matching request (or a waiting peer already
 *      exists), the server begins piping raw binary WebSocket frames
 *      between the two sockets, unmodified and uninspected.
 *   7. Server -> Client: RelayBridged / RelayError / RelayPeerDisconnected
 *      as status notifications.
 */

/** Sent by the server immediately after a client connects. */
export interface RelayChallenge {
  type: "relay.challenge";
  /** Base64-encoded random nonce the client must sign. */
  nonce: string;
}

/** Sent by the client in response to a RelayChallenge to authenticate. */
export interface RelayHello {
  type: "relay.hello";
  /** Stable UUID identifying this device. */
  deviceId: string;
  /** Base64-encoded Ed25519 public key for this device's identity. */
  publicKeyB64: string;
  /** Base64-encoded Ed25519 signature over the raw bytes of the challenge nonce. */
  nonceSignatureB64: string;
}

/** Sent by the server once RelayHello has been verified successfully. */
export interface RelayWelcome {
  type: "relay.welcome";
  deviceId: string;
}

/** Sent by an authenticated client to request bridging to another device. */
export interface RelayConnectRequest {
  type: "relay.connect";
  targetDeviceId: string;
}

/** Sent by the server once both sides of a pair are bridged and binary frames will flow. */
export interface RelayBridged {
  type: "relay.bridged";
  targetDeviceId: string;
}

/** Sent by the server when the bridged peer disconnects. */
export interface RelayPeerDisconnected {
  type: "relay.peer-disconnected";
  targetDeviceId: string;
}

/** Generic error/rejection notification from the server. */
export interface RelayError {
  type: "relay.error";
  code:
    | "invalid_message"
    | "auth_required"
    | "auth_failed"
    | "already_authenticated"
    | "invalid_target"
    | "internal_error";
  message: string;
}

export type RelayServerMessage =
  | RelayChallenge
  | RelayWelcome
  | RelayBridged
  | RelayPeerDisconnected
  | RelayError;

export type RelayClientMessage = RelayHello | RelayConnectRequest;

export function isRelayHello(msg: unknown): msg is RelayHello {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  return (
    m.type === "relay.hello" &&
    typeof m.deviceId === "string" &&
    typeof m.publicKeyB64 === "string" &&
    typeof m.nonceSignatureB64 === "string"
  );
}

export function isRelayConnectRequest(msg: unknown): msg is RelayConnectRequest {
  if (typeof msg !== "object" || msg === null) return false;
  const m = msg as Record<string, unknown>;
  return m.type === "relay.connect" && typeof m.targetDeviceId === "string";
}
