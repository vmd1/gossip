// Smoke test of the generated Swift bindings: two engines, wired together in memory, pair, exchange messages,
// persist and restore their trust, and use the standalone helpers. Run via scripts/test-swift-bindings.sh.
import Foundation

var failures = 0
func check(_ ok: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    do { if !(try ok()) { failures += 1; print("FAIL (line \(line)): \(message)") } }
    catch { failures += 1; print("FAIL (line \(line)): \(message): threw \(error)") }
}

final class FixedClock: Clock, @unchecked Sendable {
    var now: Int64 = 1_760_000_000_000
    func nowMs() -> Int64 { now }
}

struct Node {
    let core: GossipCore
    let id: NewIdentity
    var events: [Action] = []
}

final class Net {
    var nodes: [Node] = []
    var links: [String: (Int, UInt64)] = [:]   // "node:conn" -> (peer node, peer conn)
    var nextConn: UInt64 = 1
    let clock = FixedClock()

    @discardableResult
    func add(name: String, type: String, trust: String? = nil, identity: NewIdentity = generateIdentity()) throws -> Int {
        let core = try GossipCore(deviceId: identity.deviceId, deviceName: name, deviceType: type,
                                  noiseSecret: identity.noiseSecret, signingSeed: identity.signingSeed,
                                  trustJson: trust, disabledFeatures: [], clock: clock)
        nodes.append(Node(core: core, id: identity))
        return nodes.count - 1
    }

    func pump(_ node: Int, _ actions: [Action]) {
        var queue = actions.map { (node, $0) }
        while !queue.isEmpty {
            let (n, action) = queue.removeFirst()
            switch action {
            case .send(let conn, let bytes):
                if let (peer, peerConn) = links["\(n):\(conn)"] {
                    queue += nodes[peer].core.bytesReceived(conn: peerConn, bytes: bytes).map { (peer, $0) }
                }
            case .close(let conn):
                if let (peer, peerConn) = links.removeValue(forKey: "\(n):\(conn)") {
                    links.removeValue(forKey: "\(peer):\(peerConn)")
                    queue += nodes[peer].core.connectionClosed(conn: peerConn).map { (peer, $0) }
                }
            default:
                nodes[n].events.append(action)
            }
        }
    }

    func open(dialer: Int, listener: Int, pairingToken: String? = nil) throws {
        let (a, b) = (nextConn, nextConn + 1)
        nextConn += 2
        links["\(dialer):\(a)"] = (listener, b)
        links["\(listener):\(b)"] = (dialer, a)
        pump(listener, try nodes[listener].core.connectionAccepted(conn: b))
        pump(dialer, try nodes[dialer].core.dial(conn: a, target: nodes[listener].id.deviceId,
                                                 remoteStatic: nodes[listener].id.noisePublicKey, pairingToken: pairingToken))
    }

    func prompt(_ node: Int) -> (UInt64, String)? {
        for case .pairingPrompt(let conn, _, let code) in nodes[node].events.reversed() { return (conn, code) }
        return nil
    }

    func delivered(_ node: Int, kind: String) -> [Envelope] {
        nodes[node].events.compactMap { if case .deliver(let e, _) = $0, e.kind == kind { return e } else { return nil } }
    }
}

do {
    let net = Net()
    let mac = try net.add(name: "Test Mac", type: "mac")
    let phone = try net.add(name: "Test Phone", type: "android-phone")

    // ---- Pairing: the Mac shows a code, the phone scans it; both confirm the same six digits.
    net.nodes[mac].core.armPairing(token: "swift-token")
    try net.open(dialer: phone, listener: mac, pairingToken: "swift-token")
    guard let (macConn, macCode) = net.prompt(mac), let (phoneConn, phoneCode) = net.prompt(phone) else {
        fatalError("both sides must be asked to confirm")
    }
    check(macCode == phoneCode, "both screens show the same code")
    check(macCode == pairingCode(keyA: net.nodes[mac].id.noisePublicKey, keyB: net.nodes[phone].id.noisePublicKey), "code matches the helper")
    check(pairingEntryMatches(entry: macCode.replacingOccurrences(of: " ", with: ""), expected: macCode), "typed code matches")
    net.pump(mac, net.nodes[mac].core.confirmPairing(conn: macConn, accepted: true))
    net.pump(phone, net.nodes[phone].core.confirmPairing(conn: phoneConn, accepted: true))
    check(net.nodes[mac].core.isConnected(deviceId: net.nodes[phone].id.deviceId), "mac sees the phone")
    check(net.nodes[phone].core.connectedPeers() == [net.nodes[mac].id.deviceId], "phone sees the mac")

    // ---- Relay and mesh topic: pairing minted a topic on both sides; configure/status/connect round trip.
    check(net.nodes[mac].core.topicEpoch() == 1 && net.nodes[phone].core.topicEpoch() == 1, "pairing mints a shared topic")
    var topicSecret: Data?
    for case .topicChanged(let secret, let epoch) in net.nodes[mac].events + net.nodes[phone].events { if epoch == 1 { topicSecret = secret } }
    check(topicSecret?.count == 32, "TopicChanged carries a 32-byte secret to persist")
    check(net.nodes[mac].core.relayStatus() == "disabled", "relay is off by default")
    var connectURL: String?
    for case .relayConnect(let url) in net.nodes[mac].core.relayConfigure(enabled: true, origin: "wss://relay.example.test") { connectURL = url }
    check(connectURL == "wss://relay.example.test/connect", "enabling the relay asks the shell to connect")
    check(net.nodes[mac].core.relayStatus() == "connecting", "status while connecting")
    _ = net.nodes[mac].core.relaySocketOpened()
    var sentJoin = false
    let challenge = #"{"type":"relay.challenge","nonce":"gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp8=","powBits":0}"#
    for case .relaySendText(let text) in net.nodes[mac].core.relayTextReceived(text: challenge) { sentJoin = text.contains("relay.join") }
    check(sentJoin, "a challenge is answered with a signed join")
    var closed = false
    for case .relayClose in net.nodes[mac].core.relayConfigure(enabled: false, origin: "") { closed = true }
    check(closed && net.nodes[mac].core.relayStatus() == "disabled", "disabling closes the socket")
    check(!net.nodes[mac].core.isRelayed(deviceId: net.nodes[phone].id.deviceId), "LAN link is not relayed")
    _ = try net.nodes[mac].core.setTopic(secret: Data(repeating: 7, count: 32), epoch: 5)
    check(net.nodes[mac].core.topicEpoch() == 5, "set_topic loads a persisted topic")
    do { _ = try net.nodes[mac].core.setTopic(secret: Data([1]), epoch: 1); check(false, "short secret must fail") }
    catch GossipError.InvalidArgument { /* expected */ }

    // ---- Messages: signed, delivered once, with a payload.
    net.pump(phone, try net.nodes[phone].core.sendMessage(kind: "dnd.update", recipient: nil,
                                                          payloadJson: #"{"sourceDeviceId":"x","enabled":true,"isInitialSync":false}"#))
    let got = net.delivered(mac, kind: "dnd.update")
    check(got.count == 1, "mac received the dnd.update")
    check(got.first?.senderId == net.nodes[phone].id.deviceId, "sender is the phone")
    check(got.first?.payloadJson.contains("\"enabled\":true") == true, "payload preserved")

    // A raw follow-up frame travels with its envelope.
    var env = net.nodes[phone].core.newEnvelope(kind: "clipboard.update")
    env.broadcast = true
    net.pump(phone, try net.nodes[phone].core.sendWithRaw(envelope: env, raw: Data([1, 2, 3, 4, 5])))
    var rawSeen: Data?
    for case .deliver(let e, let raw) in net.nodes[mac].events where e.kind == "clipboard.update" { rawSeen = raw }
    check(rawSeen == Data([1, 2, 3, 4, 5]), "raw frame delivered with its envelope")

    // Feature toggles gate delivery.
    try net.nodes[mac].core.setDisabledFeatures(keys: ["dnd"])
    let before = net.delivered(mac, kind: "dnd.update").count
    net.pump(phone, try net.nodes[phone].core.sendMessage(kind: "dnd.update", recipient: nil, payloadJson: #"{"enabled":false}"#))
    check(net.delivered(mac, kind: "dnd.update").count == before, "a disabled feature does not deliver")
    check(featureKeys().contains("dnd") && featureForMessageType(kind: "dnd.update") == "dnd", "feature helpers")

    // Bad input is an error, not a crash.
    do { _ = try net.nodes[mac].core.sendMessage(kind: "x.y", recipient: nil, payloadJson: "[1,2]"); check(false, "array payload must fail") }
    catch GossipError.InvalidArgument { /* expected */ }
    do { _ = try net.nodes[mac].core.dial(conn: 99, target: "t", remoteStatic: Data([1, 2, 3]), pairingToken: nil); check(false, "short key must fail") }
    catch GossipError.InvalidArgument { /* expected */ }

    // ---- Persist and restore: rebuild both engines from their trust snapshots and reconnect with no prompt.
    let macTrust = net.nodes[mac].core.trustJson(), phoneTrust = net.nodes[phone].core.trustJson()
    check(macTrust.contains(net.nodes[phone].id.deviceId), "trust snapshot lists the phone")
    let net2 = Net()
    let mac2 = try net2.add(name: "Test Mac", type: "mac", trust: macTrust, identity: net.nodes[mac].id)
    let phone2 = try net2.add(name: "Test Phone", type: "android-phone", trust: phoneTrust, identity: net.nodes[phone].id)
    try net2.open(dialer: mac2, listener: phone2)
    check(net2.prompt(mac2) == nil && net2.prompt(phone2) == nil, "a trusted reconnect needs no prompt")
    check(net2.nodes[mac2].core.isConnected(deviceId: net.nodes[phone].id.deviceId), "reconnected from the persisted trust")
    check(net2.nodes[phone2].core.isConnected(deviceId: net.nodes[mac].id.deviceId), "and the responder promoted it")

    // Time moves through the injected clock: a silent peer is dropped after the heartbeat timeout.
    net2.clock.now += 70_000
    let dropped = net2.nodes[mac2].core.tick()
    net2.pump(mac2, dropped)
    check(!net2.nodes[mac2].core.isConnected(deviceId: net.nodes[phone].id.deviceId), "stale peer dropped via the injected clock")

    // ---- Standalone helpers.
    let id = generateIdentity()
    let derivedNoise = try noisePublicKey(noiseSecret: id.noiseSecret)
    let derivedSigning = try signingPublicKey(signingSeed: id.signingSeed)
    check(id.noiseSecret.count == 32 && id.signingSeed.count == 32 && id.noisePublicKey == derivedNoise, "generateIdentity")
    check(id.signingPublicKey == derivedSigning, "signing public key derivation")
    let key = Data((1...32).map { UInt8($0) })
    check(bleBeaconTag(key: key, window: 0).count == 8, "beacon tag length")
    check(bleAcceptableTags(key: key, unixSeconds: 600).count == 3, "three acceptable tags")
    let a = StreamCipher(profile: .screen, secret: key, sessionId: "s", firstEnd: true)
    let b = StreamCipher(profile: .screen, secret: key, sessionId: "s", firstEnd: false)
    let sealed = try a.seal(plaintext: Data("hello".utf8))
    let opened = try b.open(message: sealed)
    check(opened == Data("hello".utf8), "stream cipher round trip")
    do { _ = try b.open(message: sealed); check(false, "replay must fail") } catch { /* expected */ }

    // ---- Feature state machines across the FFI.
    let dndA = Dnd(persistedExpected: nil), dndB = Dnd(persistedExpected: true)
    var payloadA = "", payloadB = ""
    for case .send(let m) in dndA.initialSync(sourceDeviceId: "a") { payloadA = m.payloadJson }
    for case .send(let m) in dndB.initialSync(sourceDeviceId: "b") { payloadB = m.payloadJson }
    _ = try dndA.onUpdate(payloadJson: payloadB, nowMs: 0)
    _ = try dndB.onUpdate(payloadJson: payloadA, nowMs: 0)
    check(dndA.expected() == true && dndB.expected() == true, "DND initial sync OR-merges to on for both")

    let battery = Battery()
    var alerts = 0
    for level in [19, 19, 18] {
        let fx = try battery.onUpdate(sender: "p", payloadJson: #"{"level":\#(level),"isCharging":false}"#)
        alerts += fx.filter { if case .lowBattery = $0 { return true } else { return false } }.count
    }
    check(alerts == 1, "low-battery alert fires once per episode")
    check(battery.stateOf(sender: "p")?.level == 18, "battery state tracked")

    let ring = Ring()
    let startPayload = ringPayload(action: "start", ringId: "r1")
    check(!(try ring.onRing(sender: "peer", payloadJson: startPayload, nowMs: 0)).isEmpty && ring.isRinging(), "ring starts")
    check((try ring.onRing(sender: "peer", payloadJson: startPayload, nowMs: 1)).isEmpty, "duplicate start is a no-op")
    check(!ring.stopRinging().isEmpty && !ring.isRinging(), "ring stops")

    let clip = ClipboardGuard()
    check(clip.outgoingText(me: "m", text: "hi", sensitive: false) != nil, "first copy is sent")
    check(clip.outgoingText(me: "m", text: "hi", sensitive: false) == nil, "resync of the same value is suppressed")
    check(clip.outgoingText(me: "m", text: "secret", sensitive: true) == nil, "sensitive content is never sent")
    check(clipboardIsSensitive(types: ["org.nspasteboard.ConcealedType"]), "concealed type detected")

    let guardMedia = CommandGuard()
    let cmd = #"{"action":"next","commandId":"c1"}"#
    check((try guardMedia.accept(payloadJson: cmd))?.action == .next, "command accepted once")
    check((try guardMedia.accept(payloadJson: cmd)) == nil, "duplicate command ignored")
    let replies = ReplyGuard()
    let reply = notificationReplyPayload(notificationId: "n1", text: "ok", attemptId: "a1")
    check((try replies.accept(payloadJson: reply))?.text == "ok", "reply accepted once")
    check((try replies.accept(payloadJson: reply)) == nil, "duplicate reply ignored")

    let lock = LockOnLeave(initiallyNearby: ["phone"])
    check(lock.nearbyChanged(nearby: [], nowMs: 0, featureEnabled: true, armed: ["phone"]), "lock when an armed phone leaves")
    check(!lock.nearbyChanged(nearby: ["phone"], nowMs: 1, featureEnabled: true, armed: ["phone"]), "returning never locks")

    // ---- Instant Hotspot GATT.
    let provider = generateIdentity(), requester = generateIdentity()
    let req = try hotspotRequestCreate(requesterId: requester.deviceId, enable: true, nonce: newUuid(), nowMs: 1_000_000, signingSeed: requester.signingSeed)
    let requesterKeyB64 = baseEncodeKey(requester.signingPublicKey)
    check(hotspotRequestVerify(request: req, signingPublicKeyB64: requesterKeyB64), "request verifies")
    check(hotspotRequestIsFresh(request: req, nowMs: 1_000_000 + 60_000), "request is fresh")
    check(!hotspotRequestIsFresh(request: req, nowMs: 1_000_000 + 130_000), "stale request is refused")
    check(hotspotRequestDecode(data: hotspotRequestEncode(request: req))?.n == req.n, "request round-trips")
    let shared = try hotspotDeriveSharedKey(localX25519Secret: provider.noiseSecret, remoteX25519Public: requester.noisePublicKey)
    let sharedBack = try hotspotDeriveSharedKey(localX25519Secret: requester.noiseSecret, remoteX25519Public: provider.noisePublicKey)
    check(shared != nil && shared == sharedBack, "both sides derive the same shared key")
    let status = try hotspotStatusCreate(providerId: provider.deviceId, enabled: true, nonce: "n", signingSeed: provider.signingSeed,
                                         credentials: HotspotCredentials(ssid: "Net", passphrase: "pw", sharedKey: shared!, gcmNonce: randomBytes(len: 12)))
    check(hotspotStatusVerify(status: status, signingPublicKeyB64: baseEncodeKey(provider.signingPublicKey)), "status verifies")
    let login = try hotspotStatusDecrypt(status: status, sharedKey: sharedBack!)
    check(login?.ssid == "Net" && login?.passphrase == "pw", "credentials decrypt")
    let reassembler = HotspotChunkReassembler()
    var whole: Data?
    for chunk in hotspotEncodeChunks(message: Data(repeating: 7, count: 100)) { whole = reassembler.feed(chunk: chunk) }
    check(whole == Data(repeating: 7, count: 100), "chunks reassemble")
    let gate = HotspotRequestGate()
    check(gate.firstUse(nonce: "x") && !gate.firstUse(nonce: "x"), "replayed nonce is refused")

    // ---- Universal Control.
    let ack = ControlFrame.helloAck(info: ControlDisplayInfo(width: 2000, height: 1200, rotation: 1, backend: 0))
    check(controlFrameEncode(frame: ack).map { String(format: "%02x", $0) }.joined() == "8107d004b00100", "frame matches the shared vector")
    check(controlFrameDecode(data: controlFrameEncode(frame: ack)) == ack, "frame round-trips")
    check(controlFrameDecode(data: Data([0x7f])) == nil, "unknown frame kind is rejected")
    check(controlActionForMacKeyCode(code: 18) == .home, "Cmd+1 is Home")

    let layout = ControlLayout(localDisplays: [LocalDisplay(id: "mac", rect: Rect(x: 0, y: 0, width: 1440, height: 900))], devices: [])
    let origin = layout.place(deviceId: "tab", size: Size(width: 800, height: 500), proposedOrigin: Point(x: 1450, y: 20),
                              snapDistance: controlSnapDistance(), captureDistance: 0)
    check(origin == Point(x: 1440, y: 0), "device snaps flush to the display edge")
    let router = PointerRouter(layout: layout, pushThreshold: 30)
    router.setReadyDevices(devices: ["tab"])
    var entered = false
    for _ in 0..<10 {
        for case .enter(let id, let edge, _) in router.localMoved(delta: Point(x: 5, y: 0), location: Point(x: 1439.5, y: 300)) {
            entered = id == "tab" && edge == .left
        }
    }
    check(entered, "pushing against the edge enters the device")
    if case .remote(let id, _) = router.state() { check(id == "tab", "router is on the device") } else { check(false, "router should be remote") }
    check(!router.forceReturn(hint: nil, notifyDevice: true).isEmpty, "force return warps the cursor back")

    // ---- Relay directory.
    check(relayDirectoryAllowedDomainSuffix() == "vmd1.dev", "directory suffix")
    check(relayDirectoryParse(json: #"{"relayServer":"wss://gossip.vmd1.dev","x":1}"#, allowInsecureLocal: false) == "wss://gossip.vmd1.dev", "directory accepts the relay domain")
    check(relayDirectoryParse(json: #"{"relayServer":"wss://gossip.vmd1.dev.evil.com"}"#, allowInsecureLocal: false) == nil, "directory refuses a lookalike host")
    check(relayDirectoryParse(json: #"{"relayServer":"ws://127.0.0.1:9"}"#, allowInsecureLocal: false) == nil, "ws refused in release")
    check(relayDirectoryParse(json: #"{"relayServer":"ws://127.0.0.1:9"}"#, allowInsecureLocal: true) == "ws://127.0.0.1:9", "ws loopback allowed in development")
    let goodBlob = #"{"relayServer":"wss://a.vmd1.dev"}"#
    let adopt = relayDirectoryDecide(cachedJson: nil, fetchedJson: goodBlob, allowInsecureLocal: false)
    check(adopt.action == .adopt && adopt.changed && adopt.relayServer == "wss://a.vmd1.dev", "valid fetch is adopted")
    let keep = relayDirectoryDecide(cachedJson: goodBlob, fetchedJson: #"{"relayServer":"wss://evil.com"}"#, allowInsecureLocal: false)
    check(keep.action == .keepCached && keep.relayServer == "wss://a.vmd1.dev" && keep.rejection != nil, "invalid fetch keeps the cache")
    check(relayDirectoryDecide(cachedJson: goodBlob, fetchedJson: nil, allowInsecureLocal: false).action == .keepCached, "failed fetch keeps the cache")
    check(relayDirectoryDecide(cachedJson: "junk", fetchedJson: nil, allowInsecureLocal: false).action == .noDirectory, "corrupt cache is ignored")
    let scheduler = RelayDirectoryScheduler.withJitterPermille(jitterPermille: 0)
    check(scheduler.shouldPoll(nowMs: 10, lastSuccessMs: 5, lastAttemptMs: nil, failures: 0), "polls on launch")
    check(!scheduler.shouldPoll(nowMs: 1_000, lastSuccessMs: 10, lastAttemptMs: 10, failures: 0), "not again soon")
    check(scheduler.shouldPoll(nowMs: 10 + 6 * 3_600_000, lastSuccessMs: 10, lastAttemptMs: 10, failures: 0), "polls after six hours")
    check(scheduler.backoffMs(failures: 3) == 240_000, "backoff doubles")
    check(!scheduler.shouldPollAfterConnectFailure(nowMs: 100_000, lastAttemptMs: 10), "connect-failure poll is rate limited")
} catch {
    failures += 1
    print("FAIL: unexpected error \(error)")
}

if failures == 0 { print("swift bindings: all checks passed") } else { print("swift bindings: \(failures) failure(s)"); exit(1) }

func baseEncodeKey(_ key: Data) -> String { base64Encode(bytes: key) }
