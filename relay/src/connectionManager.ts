import { logger } from "./logger.js";
import { generateNonce, verifyNonceSignature } from "./auth.js";
import {
  isRelayConnectRequest,
  isRelayHello,
  type RelayServerMessage,
} from "./types.js";

/**
 * Minimal shape of a WebSocket-like transport the ConnectionManager needs.
 * The real `ws` WebSocket satisfies this. Tests use a lightweight mock that
 * satisfies the same shape, so all auth/pairing/bridging logic below is
 * unit-testable without a real network socket.
 */
export interface RelaySocketLike {
  send(data: string | Buffer): void;
  close(code?: number, reason?: string): void;
  on(event: "message", listener: (data: Buffer, isBinary: boolean) => void): void;
  on(event: "close", listener: () => void): void;
}

interface ConnectionState {
  socketId: string;
  socket: RelaySocketLike;
  authenticated: boolean;
  deviceId?: string;
  expectedNonce: string;
}

let nextSocketId = 1;

/**
 * Owns all relay-layer state: per-socket auth/challenge state, the
 * deviceId -> live-socket registry, pending mutual-connect requests, and
 * established bridges. Fully decoupled from `ws` / HTTP so it can be
 * exercised directly in unit tests.
 */
export class ConnectionManager {
  /** All currently-open sockets, keyed by an internal socket id (for logging). */
  private readonly connections = new Map<string, ConnectionState>();
  /** Authenticated, currently-connected sockets keyed by deviceId. */
  private readonly devicesOnline = new Map<string, ConnectionState>();
  /** Most recent relay.connect request per requesting deviceId -> targetDeviceId. */
  private readonly pendingRequests = new Map<string, string>();
  /** Established bridge partners, keyed by deviceId (symmetric). */
  private readonly bridges = new Map<string, string>();

  registerConnection(socket: RelaySocketLike): string {
    const socketId = `sock-${nextSocketId++}`;
    const nonce = generateNonce();
    const state: ConnectionState = {
      socketId,
      socket,
      authenticated: false,
      expectedNonce: nonce,
    };
    this.connections.set(socketId, state);

    logger.info("connection.open", { socketId });

    this.sendTo(state, { type: "relay.challenge", nonce });

    socket.on("message", (data, isBinary) => {
      this.handleMessage(state, data, isBinary);
    });
    socket.on("close", () => {
      this.handleClose(state);
    });

    return socketId;
  }

  private handleMessage(state: ConnectionState, data: Buffer, isBinary: boolean): void {
    if (isBinary) {
      this.handleBinaryFrame(state, data);
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(data.toString("utf8"));
    } catch {
      this.sendError(state, "invalid_message", "Control message must be valid JSON.");
      return;
    }

    if (!state.authenticated) {
      if (isRelayConnectRequest(parsed)) {
        this.sendError(state, "auth_required", "Not authenticated.");
        return;
      }
      this.handleHello(state, parsed);
      return;
    }

    if (isRelayConnectRequest(parsed)) {
      this.handleConnectRequest(state, parsed.targetDeviceId);
      return;
    }

    this.sendError(state, "invalid_message", "Unrecognized control message type.");
  }

  private handleHello(state: ConnectionState, parsed: unknown): void {
    if (!isRelayHello(parsed)) {
      this.sendError(state, "invalid_message", "Expected relay.hello.");
      return;
    }

    const valid = verifyNonceSignature(
      state.expectedNonce,
      parsed.publicKeyB64,
      parsed.nonceSignatureB64,
    );

    if (!valid) {
      logger.warn("auth.failed", { socketId: state.socketId, deviceId: parsed.deviceId });
      this.sendError(state, "auth_failed", "Signature verification failed.");
      state.socket.close(4001, "auth_failed");
      return;
    }

    state.authenticated = true;
    state.deviceId = parsed.deviceId;

    // Replace any prior connection for this deviceId (e.g. reconnect).
    const existing = this.devicesOnline.get(parsed.deviceId);
    if (existing && existing.socketId !== state.socketId) {
      logger.info("auth.replaced-existing", {
        socketId: existing.socketId,
        deviceId: parsed.deviceId,
      });
      this.teardownBridgeFor(parsed.deviceId, { notifyPeer: true });
      existing.socket.close(4000, "replaced_by_new_connection");
    }

    this.devicesOnline.set(parsed.deviceId, state);
    logger.info("auth.success", { socketId: state.socketId, deviceId: parsed.deviceId });

    this.sendTo(state, { type: "relay.welcome", deviceId: parsed.deviceId });
  }

  private handleConnectRequest(state: ConnectionState, targetDeviceId: string): void {
    const deviceId = state.deviceId;
    if (!deviceId) {
      this.sendError(state, "auth_required", "Not authenticated.");
      return;
    }

    if (targetDeviceId === deviceId) {
      this.sendError(state, "invalid_target", "Cannot connect to self.");
      return;
    }

    this.pendingRequests.set(deviceId, targetDeviceId);
    logger.info("pairing.requested", { deviceId, targetDeviceId });

    const reciprocal = this.pendingRequests.get(targetDeviceId);
    if (reciprocal !== deviceId) {
      // Peer hasn't (yet) requested us back; wait for it.
      return;
    }

    const peerState = this.devicesOnline.get(targetDeviceId);
    if (!peerState) {
      // Peer requested us previously but is no longer connected.
      return;
    }

    this.establishBridge(state, peerState);
  }

  private establishBridge(a: ConnectionState, b: ConnectionState): void {
    if (!a.deviceId || !b.deviceId) return;

    this.pendingRequests.delete(a.deviceId);
    this.pendingRequests.delete(b.deviceId);

    this.bridges.set(a.deviceId, b.deviceId);
    this.bridges.set(b.deviceId, a.deviceId);

    logger.info("bridge.established", { deviceA: a.deviceId, deviceB: b.deviceId });

    this.sendTo(a, { type: "relay.bridged", targetDeviceId: b.deviceId });
    this.sendTo(b, { type: "relay.bridged", targetDeviceId: a.deviceId });
  }

  private handleBinaryFrame(state: ConnectionState, data: Buffer): void {
    if (!state.authenticated || !state.deviceId) {
      // Drop binary frames from unauthenticated sockets; never inspected/logged beyond this.
      return;
    }

    const partnerDeviceId = this.bridges.get(state.deviceId);
    if (!partnerDeviceId) {
      return;
    }

    const partnerState = this.devicesOnline.get(partnerDeviceId);
    if (!partnerState) {
      return;
    }

    // Opaque relay: forward bytes as-is, no inspection, no logging of contents.
    partnerState.socket.send(data);
  }

  private handleClose(state: ConnectionState): void {
    this.connections.delete(state.socketId);
    logger.info("connection.close", { socketId: state.socketId, deviceId: state.deviceId });

    if (!state.deviceId) return;

    // Only clear the online registry if this socket is still the active one
    // for that deviceId (it may have already been replaced by a reconnect).
    const current = this.devicesOnline.get(state.deviceId);
    if (current && current.socketId === state.socketId) {
      this.devicesOnline.delete(state.deviceId);
    }

    this.pendingRequests.delete(state.deviceId);
    this.teardownBridgeFor(state.deviceId, { notifyPeer: true });
  }

  /** Tears down a bridge involving `deviceId`, optionally notifying the surviving peer. */
  private teardownBridgeFor(deviceId: string, opts: { notifyPeer: boolean }): void {
    const partnerDeviceId = this.bridges.get(deviceId);
    if (!partnerDeviceId) return;

    this.bridges.delete(deviceId);
    this.bridges.delete(partnerDeviceId);

    logger.info("bridge.torn-down", { deviceA: deviceId, deviceB: partnerDeviceId });

    if (opts.notifyPeer) {
      const partnerState = this.devicesOnline.get(partnerDeviceId);
      if (partnerState) {
        this.sendTo(partnerState, {
          type: "relay.peer-disconnected",
          targetDeviceId: deviceId,
        });
      }
    }
  }

  private sendTo(state: ConnectionState, message: RelayServerMessage): void {
    state.socket.send(JSON.stringify(message));
  }

  private sendError(
    state: ConnectionState,
    code: Extract<RelayServerMessage, { type: "relay.error" }>["code"],
    message: string,
  ): void {
    this.sendTo(state, { type: "relay.error", code, message });
  }

  /** Test/introspection helpers. */
  get onlineDeviceCount(): number {
    return this.devicesOnline.size;
  }

  isBridged(deviceId: string): boolean {
    return this.bridges.has(deviceId);
  }
}
