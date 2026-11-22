import XCTest
@testable import Gossip

/// Two managers wired back to back through an in-memory link: the whole offer, accept, chunk, complete exchange.
final class FileTransferManagerTests: XCTestCase {
    private var tmp: URL!
    private final class Side {
        var manager: FileTransferManager!
        let lock = NSLock()
        var saved: [(String, Data)] = []
        var offers: [IncomingFileOffer] = []
        var changes: [FileTransferInfo] = []
        func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
        func write(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
    }
    private final class Flag { private let l = NSLock(); private var v: Bool; init(_ v: Bool) { self.v = v }
        var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func pair(connected: Flag = Flag(true), autoAccept: Bool = true) -> (Side, Side) {
        let a = Side(), b = Side()
        func build(_ me: Side, _ id: String, _ other: @escaping () -> Side) {
            me.manager = FileTransferManager(
                selfId: id, partDir: tmp.appendingPathComponent("\(id)-parts"),
                sendEnvelope: { env, raw in
                    guard connected.value else { throw NSError(domain: "t", code: 1) }
                    if let raw { other().manager.handleChunk(env, raw: raw) } else { other().manager.handle(env) }
                },
                isConnected: { _ in connected.value }, pendingOutboundBytes: { 0 }, peerName: { _ in "peer" },
                saveToDownloads: { part, name in me.write { me.saved.append((name, (try? Data(contentsOf: part)) ?? Data())) }; return name },
                freeSpace: { Int64.max },
                onOffer: { offer in me.write { me.offers.append(offer) }; if autoAccept && me === b { me.manager.respond(offer.transferId, accept: true) } },
                onChanged: { info in me.write { me.changes.append(info) } },
                reofferEvery: 0.15)
        }
        build(a, "a") { b }; build(b, "b") { a }
        return (a, b)
    }

    private func randomFile(_ size: Int) throws -> URL {
        let url = tmp.appendingPathComponent("src.bin")
        var g = SystemRandomNumberGenerator()
        try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &g) }).write(to: url)
        return url
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testAFileGoesThroughIntact() throws {
        let (a, b) = pair()
        let src = try randomFile(5 * 1024 * 1024 + 123)
        _ = try a.manager.sendFile(to: "b", url: src)
        wait("received") { b.read { !b.saved.isEmpty } }
        XCTAssertEqual(b.read { b.saved[0].0 }, "src.bin")
        XCTAssertEqual(b.read { b.saved[0].1 }, try Data(contentsOf: src))
        wait("sender done") { a.read { a.changes.contains { $0.state == "done" } } }
        XCTAssertEqual(b.read { b.saved.count }, 1)
    }

    func testAnEmptyFileStillCompletes() throws {
        let (a, b) = pair()
        _ = try a.manager.sendFile(to: "b", url: try randomFile(0))
        wait("received") { b.read { !b.saved.isEmpty } }
        XCTAssertEqual(b.read { b.saved[0].1.count }, 0)
    }

    func testDecliningRejectsAndSavesNothing() throws {
        let (a, b) = pair(autoAccept: false)
        _ = try a.manager.sendFile(to: "b", url: try randomFile(2048))
        wait("offer") { b.read { !b.offers.isEmpty } }
        b.manager.respond(b.read { b.offers[0].transferId }, accept: false)
        wait("rejected") { a.read { a.changes.contains { $0.state == "rejected" } } }
        XCTAssertTrue(b.read { b.saved.isEmpty })
    }

    func testTheOfferIsNotShownTwiceWhenItIsResent() throws {
        let (a, b) = pair(autoAccept: false)
        _ = try a.manager.sendFile(to: "b", url: try randomFile(2048))
        wait("offer") { b.read { !b.offers.isEmpty } }
        Thread.sleep(forTimeInterval: 0.6) // the sender re-offers every 150 ms while unanswered
        XCTAssertEqual(b.read { b.offers.count }, 1)
    }

    func testADroppedConnectionResumesFromWhereItStopped() throws {
        let connected = Flag(true)
        let (a, b) = pair(connected: connected)
        let src = try randomFile(8 * 1024 * 1024)
        _ = try a.manager.sendFile(to: "b", url: src)
        wait("some chunks") { b.read { b.changes.contains { $0.state == "receiving" && $0.bytes >= 1024 * 1024 } } }
        connected.value = false
        Thread.sleep(forTimeInterval: 0.3)
        connected.value = true
        a.manager.peerConnected("b")
        wait("received") { b.read { !b.saved.isEmpty } }
        XCTAssertEqual(b.read { b.saved[0].1 }, try Data(contentsOf: src))
        XCTAssertEqual(b.read { b.saved.count }, 1)
    }
}
