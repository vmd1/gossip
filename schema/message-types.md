# Message Type Registry

This table is the single source of truth for every `type` value that can appear in a Connect wire envelope (see `schema/envelope.schema.json`). Because the Mac app is written in Swift and the Android app is written in Kotlin, there is no shared compiler or shared type definitions between the two codebases — this file is the only thing keeping them in sync.

**Every future feature PR, in either codebase, must add its own `type` entries to this table before shipping.** A message type that isn't registered here should not be sent or handled. Keep `payload fields` precise enough that both sides can implement `Codable` (Swift) / `kotlinx.serialization` (Kotlin) models from this table alone, without needing to read the other language's source.

Wave 1 registers only the message types needed for handshake, presence, and stubbed trust plumbing. Feature message types (e.g. `clipboard.*`, `notifications.*`, `files.*`) are out of scope for this wave and must not be added here until their owning feature is actually being built.

| type | direction | payload fields | description |
|---|---|---|---|
| `handshake.hello` | mac→android / android→mac | `noisePayload` (base64 string, Noise_IK handshake message bytes), `deviceName` (string), `deviceType` (`"mac"` \| `"android-phone"` \| `"android-tablet"`) | First message sent by the initiator to begin a Noise_IK handshake and announce basic device identity. See `docs/adr/0003-noise-ik-handshake.md`. |
| `handshake.ack` | mac→android / android→mac | `noisePayload` (base64 string, Noise_IK handshake response bytes), `deviceName` (string), `deviceType` (`"mac"` \| `"android-phone"` \| `"android-tablet"`) | Responder's reply completing the Noise_IK handshake, carrying its own handshake bytes and device identity. |
| `presence.online` | bidirectional | *(none)* | Sent once a Noise session is established and the sender considers itself actively connected. |
| `presence.offline` | bidirectional | *(none)* | Sent as a graceful notice that the sender is about to disconnect (app quit, Bluetooth/Wi-Fi teardown, etc). |
| `presence.heartbeat` | bidirectional | *(none)* | Periodic liveness ping/pong used to detect a silently-dropped connection. |
| `trust.roster_update` | bidirectional | `devices` (array of `{deviceId: uuid, publicKey: base64 string, deviceName: string, deviceType: "mac" \| "android-phone" \| "android-tablet"}`) | **Stubbed, unused until multi-device ships.** Reserved shape for gossiping the local trusted-device roster across a device group. No roster-gossip logic is implemented in Wave 1; see `docs/adr/0002-device-group-addressing.md`. |
| `trust.revoke` | bidirectional | `deviceId` (uuid) | Notifies the group that a device's trust/pairing has been revoked and its key should no longer be accepted. |
| `notification.posted` | android→mac | `id` (string, stable per-notification identifier chosen by the Android sender), `appPackage` (string), `appName` (string), `title` (string), `body` (string), `iconBase64` (string, optional, PNG bytes base64-encoded), `hasReplyAction` (bool, whether the source notification exposes a `RemoteInput`-bearing action the Mac can reply through), `timestamp` (integer, epoch ms) | Mirrors an Android status-bar notification onto the Mac as a local notification. |
| `notification.removed` | android→mac | `id` (string, matches the `id` from a prior `notification.posted`) | Tells the Mac to dismiss the previously-mirrored notification (the source notification was cleared or dismissed on Android). |
| `notification.reply` | mac→android | `id` (string, matches the `id` from a prior `notification.posted`), `text` (string) | Carries a Mac-side inline reply back to Android so it can be delivered through the original notification's `RemoteInput`/`PendingIntent`, round-tripping into the real conversation. Only valid for notifications where the matching `notification.posted` had `hasReplyAction: true`. |
