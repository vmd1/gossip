import Foundation

/// Where a small secret blob (the identity keys, the trust roster) lives: a `0600` file under Application Support
/// (`FileBlobStore`), written atomically via `PrivateFile`. Tests get a separate scratch directory per process so
/// parallel runs do not share state.
protocol SecretBlobStore {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
}

/// Picks the blob store for `account`.
///
/// This used to be the login Keychain, with a hand-rolled access-control list trusting this app by path (instead
/// of the default per-build code-hash list) so rebuilds of the self-signed binary would not keep re-prompting for
/// the login password. That access list still has to be *granted* once per item — itself a privileged Keychain
/// operation — which shows exactly that "wants to change access permissions" prompt. A plain Apple Developer ID
/// would give the app a stable Team Identifier and a real Keychain access-group entitlement, which never prompts
/// at all; without paying for one, there is no Keychain ACL configuration (tried and confirmed empirically: an
/// "allow all applications" ACL still blocks on the same prompt for a different process) that avoids it.
///
/// Deliberately moved to a private file instead, on request: no prompt, ever, at the cost of this being readable
/// by anything else already running as this user — the same exposure an actually-unrestricted Keychain ACL would
/// have had anyway, without the part where Keychain still asks permission to grant it.
enum ProductionBlobStore {
    static var isRunningUnderTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    static func make(account: String) -> SecretBlobStore {
        FileBlobStore(url: directory.appendingPathComponent("\(account).secret"))
    }

    private static let directory: URL = {
        let dir: URL
        if isRunningUnderTest {
            // Per test process, so parallel runs do not share state; the system cleans the temporary directory.
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("gossip-test-stores-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("Gossip/secrets", isDirectory: true)
        }
        PrivateFile.ensureDirectory(dir)
        return dir
    }()
}

/// A `0600` file written atomically via `PrivateFile`.
struct FileBlobStore: SecretBlobStore {
    let url: URL

    func read() -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data) -> Bool { PrivateFile.write(data, to: url) }
}
