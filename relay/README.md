# connect-relay

A minimal WebSocket relay server for Connect. It lets a paired Mac and
Android client exchange traffic when they aren't on the same local network
(e.g. the phone is on cellular). The relay is a **dumb pipe**: every payload
it forwards is already Noise-encrypted ciphertext produced by the two
clients' own end-to-end session. The relay never sees plaintext, never
parses the `[4-byte length][payload]` application framing, and never
inspects or logs frame contents — only connection metadata (device ids,
connect/disconnect/auth events) is logged.

## Running locally

```bash
npm install
npm run dev       # tsx watch mode, plain ws:// on http://localhost:8080/connect
```

Other scripts:

```bash
npm run build       # tsc -> dist/
npm start            # run the compiled server (node dist/relay.js)
npm test             # vitest unit tests
npm run smoke-test   # end-to-end smoke test against a real in-process server
```

Environment variables:

| Variable      | Default    | Meaning                                   |
| ------------- | ---------- | ------------------------------------------ |
| `PORT`        | `8080`     | HTTP/WebSocket listen port                 |
| `RELAY_PATH`  | `/connect` | WebSocket upgrade path                     |

A `GET /healthz` route returns `200 ok` for basic liveness checks.

### TLS

Locally, plain `ws://` is fine. In production, clients expect `wss://`.
This server does **not** manage TLS certificates itself — deploy it behind
a reverse proxy / load balancer / platform-managed TLS terminator (e.g.
Caddy, nginx, Fly.io, a cloud load balancer) that terminates `wss://` and
forwards plain `ws://` to this process. Certificate management and *where*
this gets hosted are explicitly deferred decisions for the project (see
"Finishing up" in the unit's task description) — this unit only delivers
the relay implementation and a `Dockerfile` for later self-hosting.

## Protocol

The relay speaks two distinct layers over the same WebSocket connection:

1. **Relay control protocol** — small JSON text messages (`relay.*`),
   defined in `src/types.ts`. This is entirely a relay-layer concern and is
   independent of the Noise session the two clients negotiate with each
   other.
2. **Opaque binary frames** — once two clients are bridged, any binary
   WebSocket frame sent by one is forwarded byte-for-byte to the other. The
   relay does not parse or buffer these beyond normal WebSocket/TCP
   backpressure; the `[4-byte length][payload]` framing and Noise
   encryption are entirely the clients' concern.

### 1. Connect + challenge

On WebSocket connect, the server immediately sends:

```json
{ "type": "relay.challenge", "nonce": "<random base64 nonce>" }
```

### 2. Authenticate (`relay.hello`)

The client signs the raw bytes of the nonce with its Ed25519 device
identity private key and responds:

```json
{
  "type": "relay.hello",
  "deviceId": "<uuid>",
  "publicKeyB64": "<Ed25519 public key, base64>",
  "nonceSignatureB64": "<Ed25519 signature over the nonce bytes, base64>"
}
```

The server verifies the signature against the claimed public key. On
success it replies:

```json
{ "type": "relay.welcome", "deviceId": "<uuid>" }
```

On failure (missing/invalid signature, malformed message) it replies with
a `relay.error` message (`code: "auth_failed"`) and closes the socket.

If a device reconnects (new socket, same `deviceId`), the new connection
replaces the old one; the old socket is closed and any bridge it held is
torn down.

### 3. Request a bridge (`relay.connect`)

Once authenticated, a client requests to be bridged to a specific peer
device:

```json
{ "type": "relay.connect", "targetDeviceId": "<uuid>" }
```

The relay bridges two sockets once **both sides** have requested each
other — i.e. if B already sent `relay.connect` targeting A, then when A
sends `relay.connect` targeting B, the bridge is established immediately
(no need for A to wait for a second round trip). Both sides receive:

```json
{ "type": "relay.bridged", "targetDeviceId": "<peer uuid>" }
```

### 4. Bridged binary relay

After `relay.bridged`, any **binary** WebSocket frame sent by either side
is forwarded verbatim to the other. Text (JSON) frames are still accepted
for control purposes (though no further control messages are needed for a
simple bridge).

### 5. Disconnects

If either side of a bridged pair disconnects, the relay tears down the
bridge and notifies the surviving peer:

```json
{ "type": "relay.peer-disconnected", "targetDeviceId": "<uuid that dropped>" }
```

The surviving peer's own socket is **not** closed — it may reconnect or
issue a new `relay.connect` later.

### Error messages

```json
{ "type": "relay.error", "code": "auth_failed", "message": "..." }
```

Possible `code` values: `invalid_message`, `auth_required`, `auth_failed`,
`already_authenticated`, `invalid_target`, `internal_error`.

## Docker

```bash
docker build -t connect-relay .
docker run -p 8080:8080 connect-relay
```

Set `PORT` / `RELAY_PATH` via `-e` as needed. Put a TLS-terminating proxy
in front for production use.

## Testing

- `test/auth.test.ts` — nonce generation and Ed25519 signature verification
  (valid signature, wrong key, wrong nonce, malformed input, wrong-length
  signature).
- `test/connectionManager.test.ts` — the full auth handshake and
  device-pairing/bridging state machine, exercised against an in-process
  mock WebSocket (`test/mockSocket.ts`) so it needs no real network I/O.
- `scripts/smoke-test.ts` — end-to-end check against a real server instance
  and real `ws` clients: two distinct fake Ed25519 identities authenticate,
  request a bridge to each other, and a raw binary frame sent by one is
  confirmed to arrive byte-for-byte on the other.
