import Foundation

/// The pure rules of file transfer (`docs/plans/file-transfer.md`), pinned by `schema/file-transfer-cases.json` and
/// mirrored by the Android app.
enum FileTransferRules {
    static let chunkSize = 1_048_576
    static let maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxIncoming = 3
    static let maxNameLength = 120

    /// A name from the wire reduced to a safe single path component. Never empty, never contains a separator.
    static func sanitizeName(_ raw: String) -> String {
        var last = raw
        if let i = last.lastIndex(of: "/") { last = String(last[last.index(after: i)...]) }
        if let i = last.lastIndex(of: "\\") { last = String(last[last.index(after: i)...]) }
        let noControl = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        var cleaned = noControl.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "file" }
        if cleaned.count <= maxNameLength { return cleaned }
        var ext = ""
        if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex {
            let tail = String(cleaned[dot...])
            if tail.count <= 16 { ext = tail }
        }
        return String(cleaned.prefix(maxNameLength - ext.count)) + ext
    }

    /// `name`, or `name (2).ext`, `name (3).ext`, ... until `isTaken` says the name is free.
    static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        var stem = name, ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot]); ext = String(name[dot...])
        }
        var n = 2
        while true {
            let candidate = "\(stem) (\(n))\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    static func chunkCount(size: Int64, chunkSize: Int = chunkSize) -> Int {
        Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    static func chunkLength(size: Int64, chunkSize: Int, index: Int) -> Int {
        let start = Int64(index) * Int64(chunkSize)
        return Int(max(0, min(Int64(chunkSize), size - start)))
    }

    /// The first chunk index not yet received: what a receiver asks the sender to resume from.
    static func nextIndex(received: Set<Int>) -> Int {
        var i = 0
        while received.contains(i) { i += 1 }
        return i
    }
}
