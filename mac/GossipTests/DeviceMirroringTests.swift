import XCTest
@testable import Gossip

final class LauncherInstallerTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var gossip: URL!
    private var embedded: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("launcher-tests-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        gossip = applications.appendingPathComponent("Gossip.app", isDirectory: true)
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        embedded = gossip.appendingPathComponent("Contents/SharedSupport/Device Mirroring.app", isDirectory: true)
        try makeApp(at: embedded, executable: "v1")
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    private func makeApp(at url: URL, executable: String, bundleId: String = LauncherInstaller.launcherBundleIdentifier) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleExecutable": "launcher"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(executable.utf8).write(to: url.appendingPathComponent("Contents/MacOS/launcher"))
    }

    private func installer(gossipURL: URL? = nil, allowed: [URL]? = nil) -> LauncherInstaller {
        LauncherInstaller(embeddedLauncherURL: embedded, gossipURL: gossipURL ?? gossip, allowedDirectories: allowed ?? [applications])
    }

    private var installed: URL { applications.appendingPathComponent("Device Mirroring.app") }

    /// These tests run inside the sandboxed Gossip app, where every file created is quarantined and the
    /// flag cannot be cleared — the reason the installer is run by the non-sandboxed launcher in real use
    /// (verified live: see the launcher's `main.swift`). Quarantine-dependent assertions are skipped there.
    private var runningSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    func testInstallsNextToGossipThenIsUpToDate() {
        XCTAssertEqual(installer().status(), .missing)
        XCTAssertEqual(installer().install(), .installed)
        XCTAssertTrue(fm.fileExists(atPath: installed.path))
        XCTAssertTrue(installer().isInstalled)
        if runningSandboxed { return }   // the copy is quarantined here, so it would report .quarantined
        XCTAssertEqual(installer().status(), .current)
        XCTAssertEqual(installer().install(), .upToDate)
    }

    func testRefreshesWhenTheEmbeddedLauncherChanges() throws {
        XCTAssertEqual(installer().install(), .installed)
        try Data("v2".utf8).write(to: embedded.appendingPathComponent("Contents/MacOS/launcher"))
        XCTAssertEqual(installer().status(), .outdated)
        XCTAssertEqual(installer().install(), .updated)
        XCTAssertEqual(LauncherInstaller.fingerprint(of: installed), LauncherInstaller.fingerprint(of: embedded))
    }

    func testRepairsAQuarantinedCopy() throws {
        try XCTSkipIf(runningSandboxed, "a sandboxed process can neither set nor clear the quarantine flag")
        XCTAssertEqual(installer().install(), .installed)
        // What a sandboxed app leaves behind: a quarantine flag the launcher must clear.
        let value = "0086;00000000;Gossip;"
        XCTAssertEqual(setxattr(installed.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        XCTAssertTrue(LauncherInstaller.hasQuarantine(installed))
        XCTAssertEqual(installer().status(), .quarantined)
        XCTAssertEqual(installer().install(), .updated)
        XCTAssertFalse(LauncherInstaller.hasQuarantine(installed))
        XCTAssertEqual(installer().status(), .current)
    }

    func testNeverOverwritesAnotherAppWithTheSameName() throws {
        try makeApp(at: installed, executable: "other", bundleId: "com.example.Other")
        if case .notApplicable = installer().status() {} else { XCTFail("expected notApplicable") }
        if case .notApplicable = installer().install() {} else { XCTFail("expected notApplicable") }
        XCTAssertEqual(LauncherInstaller.bundleIdentifier(of: installed), "com.example.Other")
        XCTAssertFalse(installer().isInstalled)
    }

    func testDoesNothingWhenGossipIsNotInAnApplicationsFolder() throws {
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let elsewhere = downloads.appendingPathComponent("Gossip.app")
        if case .notApplicable = installer(gossipURL: elsewhere).install() {} else { XCTFail("expected notApplicable") }
        XCTAssertFalse(fm.fileExists(atPath: downloads.appendingPathComponent("Device Mirroring.app").path))
    }

    func testNotApplicableWithoutAnEmbeddedLauncher() {
        let none = LauncherInstaller(embeddedLauncherURL: nil, gossipURL: gossip, allowedDirectories: [applications])
        if case .notApplicable = none.status() {} else { XCTFail("expected notApplicable") }
    }
}

final class GossipLocatorTests: XCTestCase {
    func testPrefersTheGossipSittingNextToTheLauncher() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Gossip.app"), withIntermediateDirectories: true)
        let launcher = dir.appendingPathComponent("Device Mirroring.app")
        let stray = URL(fileURLWithPath: "/somewhere/else/Gossip.app")
        XCTAssertEqual(GossipLocator.locate(launcherURL: launcher, lookUpByBundleIdentifier: { _ in stray })?.lastPathComponent, "Gossip.app")
        XCTAssertEqual(GossipLocator.locate(launcherURL: launcher, lookUpByBundleIdentifier: { _ in stray })?.deletingLastPathComponent().path, dir.path)
    }

    func testFallsBackToTheBundleIdentifierLookup() {
        let launcher = URL(fileURLWithPath: "/nonexistent-dir/Device Mirroring.app")
        let found = URL(fileURLWithPath: "/Applications/Gossip.app")
        var asked: String?
        XCTAssertEqual(GossipLocator.locate(launcherURL: launcher, lookUpByBundleIdentifier: { asked = $0; return found }), found)
        XCTAssertEqual(asked, GossipLocator.gossipBundleIdentifier)
        XCTAssertNil(GossipLocator.locate(launcherURL: launcher, lookUpByBundleIdentifier: { _ in nil }))
    }
}

final class DeviceMirroringRowsTests: XCTestCase {
    private func device(_ id: String, _ name: String, _ type: DeviceType) -> TrustedDevice {
        TrustedDevice(deviceId: id, publicKeyBase64: "k", deviceName: name, deviceType: type, addedAt: Date(), signingPublicKeyBase64: nil)
    }

    func testListsOnlyMirrorableDevicesConnectedFirstThenByName() {
        let devices = [device("mac", "Other Mac", .mac), device("t", "Tablet", .androidTablet),
                       device("p", "Pixel", .androidPhone), device("a", "Alpha", .androidPhone)]
        let rows = DeviceMirroringRows.rows(devices: devices, connectedIds: ["t"], batteries: ["t": BatteryState(level: 50, isCharging: false)])
        XCTAssertEqual(rows.map(\.id), ["t", "a", "p"])   // Mac excluded; connected tablet first; then Alpha, Pixel
        XCTAssertEqual(rows.first?.battery, BatteryState(level: 50, isCharging: false))
        XCTAssertEqual(rows.map(\.isConnected), [true, false, false])
    }

    func testEmptyWhenNothingIsPaired() {
        XCTAssertTrue(DeviceMirroringRows.rows(devices: [], connectedIds: [], batteries: [:]).isEmpty)
    }
}

final class DeviceConnectivityTests: XCTestCase {
    func testDirectBeatsMeshBeatsNone() {
        XCTAssertEqual(DeviceConnectivity.classify("a", directIds: ["a"], meshIds: ["a"]), .direct)
        XCTAssertEqual(DeviceConnectivity.classify("b", directIds: ["a"], meshIds: ["b"]), .mesh)
        XCTAssertEqual(DeviceConnectivity.classify("c", directIds: ["a"], meshIds: ["b"]), .none)
    }

    func testMeshReachableIsHeardRecentlyNotDirectAndNotUs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let heard: [String: Date] = [
            "fresh": now.addingTimeInterval(-10), "stale": now.addingTimeInterval(-DeviceConnectivity.meshTTL - 1),
            "direct": now.addingTimeInterval(-5), "me": now.addingTimeInterval(-1), "edge": now.addingTimeInterval(-DeviceConnectivity.meshTTL + 1)
        ]
        XCTAssertEqual(DeviceConnectivity.meshReachable(lastHeard: heard, directIds: ["direct"], selfId: "me", now: now), ["fresh", "edge"])
    }

    func testMirrorRowsSortDirectThenMeshThenOffline() {
        func dev(_ id: String) -> TrustedDevice { TrustedDevice(deviceId: id, publicKeyBase64: "k", deviceName: id, deviceType: .androidPhone, addedAt: Date()) }
        let rows = DeviceMirroringRows.rows(devices: [dev("c-off"), dev("b-mesh"), dev("a-direct")],
                                            connectedIds: ["a-direct"], meshIds: ["b-mesh"], batteries: [:])
        XCTAssertEqual(rows.map(\.id), ["a-direct", "b-mesh", "c-off"])
        XCTAssertEqual(rows.map(\.isConnected), [true, false, false])   // only a direct connection can mirror
    }
}
