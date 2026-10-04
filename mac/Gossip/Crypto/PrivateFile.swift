import Foundation

/// Creates files and directories that are private to the user from the first byte written,
/// instead of writing with default permissions and tightening them afterwards.
enum PrivateFile {
    /// Creates `url` (and parents) as `0700` if missing, and tightens an existing one.
    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Atomically replaces `url` with `data`, created `0600` (temp file opened `O_EXCL|0600`, then renamed).
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        var offset = 0
        let ok: Bool = data.withUnsafeBytes { buf in
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            return false
        }
        return true
    }
}
