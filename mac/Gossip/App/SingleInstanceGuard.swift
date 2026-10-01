import AppKit
import Foundation

/// Makes a second Gossip process impossible: the first instance takes an exclusive, non-blocking
/// `flock` on a lock file and holds it for its whole lifetime; any later launch fails to get the
/// lock, brings the running instance forward and exits before it touches the network, BLE or the
/// pasteboard. Unlike a "look for another `NSRunningApplication`" check, `flock` is atomic, so two
/// launches racing each other can't both pass (or both quit), and the OS releases the lock if the
/// first instance crashes, so a stale lock can't lock the user out.
enum SingleInstanceGuard {
    /// Kept open for the process lifetime — closing it would release the lock.
    private static var lockFD: Int32 = -1

    /// Returns `true` if this process is now the only instance. Idempotent.
    static func acquire(lockURL: URL = defaultLockURL) -> Bool {
        if lockFD >= 0 { return true }
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }  // can't create the lock file: fail open rather than refuse to start
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd
        return true
    }

    /// Call first thing at launch: exits (after surfacing the existing instance) if another is running.
    static func exitIfAnotherInstanceIsRunning() {
        // Unit tests run inside a host copy of the app that must not be blocked by a real running one.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !acquire() else { return }
        NSLog("Gossip: another instance is already running — exiting")
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate()
        }
        exit(0)
    }

    private static var defaultLockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gossip/instance.lock")
    }
}
