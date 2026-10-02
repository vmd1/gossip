import Foundation

// Scripted Universal Control driver: speaks the real Mac-side protocol (the same ControlProtocol.swift and
// ControlWebSocketClient.swift the app uses) to a device, as the Mac would, so the tablet's behaviour can be
// asserted from logcat. Built and run by run-tablet-e2e.sh.
//
//   driver <host> <port> <sessionId> <secretHex> <scenario>
//
// Scenarios: basic (enter, hover, click, scroll, type, leave) | drift (measure cursor travel for a series of
// moves) | idle (hello only, then wait; used for the screen-stays-on assertion).

let args = CommandLine.arguments
guard args.count >= 6, let port = UInt16(args[2]) else { print("usage: driver host port sessionId secretHex scenario"); exit(2) }
let secret = Data(stride(from: 0, to: args[4].count, by: 2).map { UInt8(args[4].dropFirst($0).prefix(2), radix: 16)! })
guard let client = ControlWebSocketClient(host: args[1], port: port, sessionId: args[3], secret: secret, label: "e2e") else { print("bad address"); exit(2) }

let ready = DispatchSemaphore(value: 0)
var info: ControlDisplayInfo?
var closed = false
client.onEvent = { e in
    switch e {
    case .ready(let i): info = i; ready.signal()
    case .frame(let f): print("device frame:", f)
    case .closed(let err): closed = true; print("closed:", err.map { "\($0)" } ?? "clean"); ready.signal()
    }
}
client.connect()
guard ready.wait(timeout: .now() + 10) == .success, let display = info else { print("FAIL: no hello ack"); exit(1) }
print("ready: \(display.width)x\(display.height) rotation=\(display.rotation) backend=\(display.backend)")

func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
func marker(_ s: String) { print("MARK \(s)"); fflush(stdout) }

switch args[5] {
case "basic":
    marker("enter")
    client.send(.enter(edge: .left, position: 32768)); pause(1.2)
    marker("hover")
    for _ in 0..<20 { client.send(.mouseMove(dx: 6, dy: 3)); pause(0.012) }
    pause(0.3)
    marker("click")
    client.send(.buttons(1)); pause(0.05); client.send(.buttons(0)); pause(0.2)
    marker("rightclick")
    client.send(.buttons(2)); pause(0.05); client.send(.buttons(0)); pause(0.2)
    marker("scroll")
    client.send(.scroll(dx: 0, dy: 120)); pause(0.1); client.send(.scroll(dx: 0, dy: -240)); pause(0.1); client.send(.scroll(dx: 120, dy: 0)); pause(0.3)
    marker("keys")
    client.send(.key(usage: 0x04, down: true, modifiers: 0)); client.send(.key(usage: 0x04, down: false, modifiers: 0)); pause(0.1)
    client.send(.key(usage: 0xE0, down: true, modifiers: 0x01)); client.send(.key(usage: 0x04, down: true, modifiers: 0x01))
    client.send(.key(usage: 0x04, down: false, modifiers: 0x01)); client.send(.key(usage: 0xE0, down: false, modifiers: 0)); pause(0.2)
    client.send(.key(usage: 0x28, down: true, modifiers: 0)); client.send(.key(usage: 0x28, down: false, modifiers: 0)); pause(0.2)
    marker("text")
    client.send(.text("Hello 42")); pause(0.5)
    client.send(.text("héllo ✓")); pause(1.0)
    marker("leave")
    client.send(.leave); pause(0.8)
    marker("end")
case "drift":
    // Slam to the corner by entering at the top-left, then measure how far the cursor really travels.
    let runs: [(String, Int, Int, Double)] = [("60x10@16ms", 60, 10, 0.016), ("120x5@8ms", 120, 5, 0.008), ("30x20@8ms", 30, 20, 0.008), ("300x2@10ms", 300, 2, 0.010), ("12x50@50ms", 12, 50, 0.05)]
    for (label, n, d, delay) in runs {
        client.send(.enter(edge: .top, position: 0)); pause(1.0)
        marker("start \(label) intended=\(n * d)")
        for _ in 0..<n { client.send(.mouseMove(dx: Int16(d), dy: 0)); pause(delay) }
        pause(0.5)
        marker("stop \(label)")
        client.send(.leave); pause(0.6)
    }
case "smooth":
    // Constant-velocity motion at 250 Hz (3 px per frame), paced by absolute deadlines, so any irregularity in
    // what the device reports is the device/transport, not the sender.
    client.send(.enter(edge: .left, position: 32768)); pause(1.2)
    marker("smooth-start")
    let period = 0.004, start = Date()
    for i in 0..<750 {
        client.send(.mouseMove(dx: 3, dy: 0))
        let wait = start.addingTimeInterval(Double(i + 1) * period).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }
    pause(0.5)
    marker("smooth-stop")
    client.send(.leave); pause(0.6)
case "hold":
    // Enter and park the pointer 300 px right of the left edge, 200 px down, then wait so state can be inspected.
    client.send(.enter(edge: .left, position: 20000)); pause(1.2)
    marker("moving")
    for _ in 0..<30 { client.send(.mouseMove(dx: 10, dy: 0)); pause(0.016) }
    pause(0.3); marker("parked")
    pause(25)
    client.send(.leave); pause(0.6)
case "locate":
    // Closed-loop check: ask the device where its cursor really is, at rest and after fast and slow motion.
    // run-tablet-e2e.sh compares each answer with the position Android itself delivered to the probe activity.
    client.send(.enter(edge: .left, position: 20000)); pause(1.5)
    marker("query-entry"); client.send(.cursorQuery(token: 1)); pause(1.0)
    for _ in 0..<40 { client.send(.mouseMove(dx: 30, dy: 0)); pause(0.012) }       // fast: heavily accelerated
    pause(0.4); marker("query-after-fast"); client.send(.cursorQuery(token: 2)); pause(1.0)
    for _ in 0..<40 { client.send(.mouseMove(dx: -4, dy: 3)); pause(0.016) }        // slow: not accelerated
    pause(0.4); marker("query-after-slow"); client.send(.cursorQuery(token: 3)); pause(1.0)
    client.send(.leave); pause(0.6)
case "nav":
    // Navigation shortcuts: Home leaves the probe activity; Back would too, Notifications opens the shade.
    client.send(.enter(edge: .left, position: 32768)); pause(1.5)
    marker("home"); client.send(.action(.home)); pause(2.0)
    marker("notifications"); client.send(.action(.notifications)); pause(2.0)
    marker("back"); client.send(.action(.back)); pause(1.5)
    marker("appswitch"); client.send(.action(.appSwitch)); pause(2.0)
    client.send(.action(.home)); pause(1.0)
    client.send(.leave); pause(0.6)
case "idle":
    marker("idle"); pause(5)
default: print("unknown scenario"); exit(2)
}
client.close(); pause(0.3)
exit(0)
