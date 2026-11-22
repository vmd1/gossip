import Foundation
import CryptoKit

struct IncomingFileOffer: Equatable {
    let transferId: String
    let peerId: String
    let peerName: String
    let name: String
    let size: Int64
}

struct FileTransferInfo: Equatable {
    let transferId: String
    let peerId: String
    let name: String
    let size: Int64
    let outgoing: Bool
    /// offered | receiving | sending | waiting | done | failed | rejected | cancelled
    let state: String
    let bytes: Int64
}

/// File transfer (`docs/plans/file-transfer.md`, `schema/message-types.md`'s `file.*` rows): the Mac half of the protocol the
/// Windows and Android apps speak. The receiver must accept every offer; chunks are 1 MiB raw frames written at offset
/// `index * chunkSize` (a repeat is harmless); `file.accept(next)` is both the answer and the resume request; the sender
/// re-offers on every fresh connection and every 30 s while unanswered. Every handler is idempotent.
///
/// Transport, clock and disk are injected so the state machine runs in unit tests. All state lives on `queue`.
final class FileTransferManager {
    private final class Outgoing {
        let id: String, peerId: String, url: URL, name: String, size: Int64, sha256: String
        var state = "offered"
        let offeredAt = Date()
        var sender: Task<Void, Never>?
        var sent: Int64 = 0
        init(id: String, peerId: String, url: URL, name: String, size: Int64, sha256: String) {
            self.id = id; self.peerId = peerId; self.url = url; self.name = name; self.size = size; self.sha256 = sha256
        }
    }

    private final class Incoming {
        let id: String, peerId: String, peerName: String, name: String, size: Int64, chunkSize: Int, sha256: String, part: URL
        var accepted = false
        var received = Set<Int>()
        var handle: FileHandle?
        var promptTimeout: DispatchWorkItem?
        init(id: String, peerId: String, peerName: String, name: String, size: Int64, chunkSize: Int, sha256: String, part: URL) {
            self.id = id; self.peerId = peerId; self.peerName = peerName; self.name = name; self.size = size
            self.chunkSize = chunkSize; self.sha256 = sha256; self.part = part
        }
    }

    private let selfId: String
    private let partDir: URL
    private let sendEnvelope: (Envelope, Data?) throws -> Void
    private let isConnected: (String) -> Bool
    private let pendingOutboundBytes: () -> Int
    private let peerName: (String) -> String
    private let saveToDownloads: (URL, String) -> String?
    private let freeSpace: () -> Int64
    private let onOffer: (IncomingFileOffer) -> Void
    private let onChanged: (FileTransferInfo) -> Void
    private let offerAnswerTimeout: TimeInterval
    private let queue = DispatchQueue(label: "dev.vmd1.gossip.filetransfer")
    private var outgoing: [String: Outgoing] = [:]
    private var incoming: [String: Incoming] = [:]
    private var finished: [String] = []
    private var reofferTimer: DispatchSourceTimer?

    private static let giveUpAfter: TimeInterval = 10 * 60
    private static let maxQueued = 8 * 1024 * 1024
    private static let spaceMargin: Int64 = 100 * 1024 * 1024
    private static let active: Set<String> = ["offered", "sending", "waiting"]

    init(selfId: String, partDir: URL,
         sendEnvelope: @escaping (Envelope, Data?) throws -> Void,
         isConnected: @escaping (String) -> Bool,
         pendingOutboundBytes: @escaping () -> Int,
         peerName: @escaping (String) -> String,
         saveToDownloads: @escaping (URL, String) -> String?,
         freeSpace: @escaping () -> Int64,
         onOffer: @escaping (IncomingFileOffer) -> Void,
         onChanged: @escaping (FileTransferInfo) -> Void = { _ in },
         offerAnswerTimeout: TimeInterval = 120,
         reofferEvery: TimeInterval = 30) {
        self.selfId = selfId; self.partDir = partDir; self.sendEnvelope = sendEnvelope; self.isConnected = isConnected
        self.pendingOutboundBytes = pendingOutboundBytes; self.peerName = peerName; self.saveToDownloads = saveToDownloads
        self.freeSpace = freeSpace; self.onOffer = onOffer; self.onChanged = onChanged; self.offerAnswerTimeout = offerAnswerTimeout
        try? FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reofferEvery, repeating: reofferEvery)
        timer.setEventHandler { [weak self] in self?.reoffer(onlyPeer: nil) }
        timer.resume()
        reofferTimer = timer
    }

    deinit { reofferTimer?.cancel() }

    // MARK: entry points

    /// Handles a `file.*` envelope (metadata only; chunks come through `handleChunk`).
    func handle(_ envelope: Envelope) {
        queue.async { [self] in
            guard let id = envelope.payload["transferId"]?.stringValue else { return }
            switch envelope.type {
            case "file.offer": onOfferMessage(envelope.senderId, id, envelope.payload)
            case "file.accept": onAccept(envelope.senderId, id, envelope.payload)
            case "file.reject": onReject(envelope.senderId, id)
            case "file.complete": onComplete(envelope.senderId, id, envelope.payload)
            case "file.cancel": onCancel(envelope.senderId, id)
            default: break
            }
        }
    }

    /// The raw-frame handler for `file.chunk`.
    func handleChunk(_ envelope: Envelope, raw: Data) {
        queue.async { [self] in
            guard let id = envelope.payload["transferId"]?.stringValue, let index = envelope.payload["index"]?.numberValue.map(Int.init) else { return }
            onChunk(envelope.senderId, id, index, raw)
        }
    }

    /// A trusted device finished connecting: re-offer whatever is still unfinished for it.
    func peerConnected(_ peerId: String) { queue.async { [self] in reoffer(onlyPeer: peerId) } }

    /// Offers a file; returns the transfer id.
    func sendFile(to peerId: String, url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= FileTransferRules.maxFileBytes else { throw NSError(domain: "FileTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Files over 2 GiB cannot be sent."]) }
        var hasher = SHA256()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let t = Outgoing(id: UUID().uuidString, peerId: peerId, url: url, name: url.lastPathComponent, size: size, sha256: sha)
        queue.async { [self] in
            outgoing[t.id] = t
            offer(t)
            changed(t)
        }
        return t.id
    }

    func cancel(_ transferId: String) {
        queue.async { [self] in
            if let t = outgoing[transferId], Self.active.contains(t.state) {
                t.sender?.cancel(); t.state = "cancelled"
                send(t.peerId, "file.cancel", ["transferId": .string(t.id)]); changed(t)
            }
            if let i = incoming.removeValue(forKey: transferId) {
                i.promptTimeout?.cancel(); discard(i)
                send(i.peerId, "file.cancel", ["transferId": .string(i.id)])
            }
        }
    }

    /// The user's answer to a prompt shown through `onOffer`.
    func respond(_ transferId: String, accept: Bool) {
        queue.async { [self] in
            guard let t = incoming[transferId], !t.accepted else { return }
            t.promptTimeout?.cancel()
            if !accept { incoming[transferId] = nil; reject(t.peerId, transferId, "declined"); return }
            // Whole chunks left in a .part file (a dropped connection, an app restart) are kept: that is what `next` resumes from.
            let existing = (try? FileManager.default.attributesOfItem(atPath: t.part.path)[.size] as? NSNumber)?.int64Value ?? 0
            let have = Int(min(existing / Int64(t.chunkSize), Int64(FileTransferRules.chunkCount(size: t.size, chunkSize: t.chunkSize))))
            if !FileManager.default.fileExists(atPath: t.part.path) { FileManager.default.createFile(atPath: t.part.path, contents: nil) }
            guard let handle = try? FileHandle(forUpdating: t.part) else { incoming[transferId] = nil; reject(t.peerId, transferId, "no_space"); return }
            try? handle.truncate(atOffset: UInt64(min(t.size, Int64(have) * Int64(t.chunkSize))))
            t.handle = handle
            t.received = Set(0..<have)
            t.accepted = true
            incomingChanged(t)
            if t.size == 0 { finish(t); return }
            sendAccept(t)
        }
    }

    // MARK: sending

    private func offer(_ t: Outgoing) {
        send(t.peerId, "file.offer", [
            "transferId": .string(t.id), "name": .string(t.name), "size": .number(Double(t.size)),
            "sha256": .string(t.sha256), "chunkSize": .number(Double(FileTransferRules.chunkSize)),
        ])
    }

    private func reoffer(onlyPeer: String?) {
        for t in outgoing.values where Self.active.contains(t.state) {
            if let onlyPeer, t.peerId != onlyPeer { continue }
            if Date().timeIntervalSince(t.offeredAt) > Self.giveUpAfter && t.state == "offered" { t.state = "failed"; changed(t); continue }
            if !isConnected(t.peerId) { continue }
            if onlyPeer == nil && t.state != "offered" && t.state != "waiting" { continue }
            offer(t)
        }
    }

    private func startSending(_ t: Outgoing, from: Int) {
        t.sender?.cancel()
        t.state = "sending"
        t.sender = Task.detached { [weak self] in
            guard let self else { return }
            let count = FileTransferRules.chunkCount(size: t.size)
            guard let reader = try? FileHandle(forReadingFrom: t.url) else { self.queue.async { t.state = "waiting" }; return }
            defer { try? reader.close() }
            var i = from
            while i < count, !Task.isCancelled {
                while self.pendingOutboundBytes() > Self.maxQueued {
                    if !self.isConnected(t.peerId) { self.queue.async { t.state = "waiting"; self.changed(t) }; return }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if Task.isCancelled { return }
                }
                if !self.isConnected(t.peerId) { self.queue.async { t.state = "waiting"; self.changed(t) }; return }
                let length = FileTransferRules.chunkLength(size: t.size, chunkSize: FileTransferRules.chunkSize, index: i)
                try? reader.seek(toOffset: UInt64(i) * UInt64(FileTransferRules.chunkSize))
                guard let data = try? reader.read(upToCount: length), data.count == length else { self.queue.async { t.state = "waiting" }; return }
                let envelope = Envelope(type: "file.chunk", senderId: self.selfId, recipientId: t.peerId, hasRawFollowup: true,
                                        payload: .object(["transferId": .string(t.id), "index": .number(Double(i))]))
                do { try self.sendEnvelope(envelope, data) } catch { self.queue.async { t.state = "waiting"; self.changed(t) }; return }
                let end = Int64(i) * Int64(FileTransferRules.chunkSize) + Int64(length)
                self.queue.async { t.sent = max(t.sent, end); if i % 4 == 0 { self.changed(t) } }
                i += 1
            }
            if !Task.isCancelled { self.queue.async { t.state = "waiting"; self.changed(t) } } // waiting for file.complete
        }
    }

    // MARK: handling (on queue)

    private func onOfferMessage(_ sender: String, _ id: String, _ p: JSONValue) {
        if finished.contains(id) { send(sender, "file.complete", ["transferId": .string(id), "ok": .bool(true)]); return }
        if let known = incoming[id] { if known.peerId == sender && known.accepted { sendAccept(known) }; return } // never prompt twice
        guard let sizeD = p["size"]?.numberValue else { return }
        let size = Int64(sizeD)
        let chunk = p["chunkSize"]?.numberValue.map(Int.init) ?? FileTransferRules.chunkSize
        if size < 0 || size > FileTransferRules.maxFileBytes || chunk < 1024 || chunk > 8 * 1024 * 1024 { reject(sender, id, "too_large"); return }
        if incoming.count >= FileTransferRules.maxIncoming { reject(sender, id, "busy"); return }
        if freeSpace() < size + Self.spaceMargin { reject(sender, id, "no_space"); return }
        let name = FileTransferRules.sanitizeName(p["name"]?.stringValue ?? "file")
        let t = Incoming(id: id, peerId: sender, peerName: peerName(sender), name: name, size: size, chunkSize: chunk,
                         sha256: (p["sha256"]?.stringValue ?? "").lowercased(), part: partDir.appendingPathComponent("\(id).part"))
        incoming[id] = t
        // Decline is the default after two minutes.
        let timeout = DispatchWorkItem { [weak self, weak t] in
            guard let self, let t, !t.accepted, self.incoming[id] === t else { return }
            self.incoming[id] = nil
            self.reject(sender, id, "declined")
        }
        t.promptTimeout = timeout
        queue.asyncAfter(deadline: .now() + offerAnswerTimeout, execute: timeout)
        onOffer(IncomingFileOffer(transferId: id, peerId: sender, peerName: t.peerName, name: name, size: size))
    }

    private func sendAccept(_ t: Incoming) {
        send(t.peerId, "file.accept", ["transferId": .string(t.id), "next": .number(Double(FileTransferRules.nextIndex(received: t.received)))])
    }

    private func reject(_ peer: String, _ id: String, _ reason: String) {
        send(peer, "file.reject", ["transferId": .string(id), "reason": .string(reason)])
    }

    private func onChunk(_ sender: String, _ id: String, _ index: Int, _ raw: Data) {
        guard let t = incoming[id], t.peerId == sender, t.accepted, let handle = t.handle else { return } // unknown or finished: dropped
        let expected = FileTransferRules.chunkLength(size: t.size, chunkSize: t.chunkSize, index: index)
        guard index >= 0, expected > 0, raw.count == expected else { return }
        do { try handle.seek(toOffset: UInt64(index) * UInt64(t.chunkSize)); try handle.write(contentsOf: raw) } catch { return }
        t.received.insert(index)
        let done = t.received.count == FileTransferRules.chunkCount(size: t.size, chunkSize: t.chunkSize)
        if index % 4 == 0 || done { incomingChanged(t) }
        if done { finish(t) }
    }

    private func finish(_ t: Incoming) {
        guard incoming[t.id] === t else { return } // already finished (a duplicate last chunk)
        incoming[t.id] = nil
        try? t.handle?.synchronize(); try? t.handle?.close(); t.handle = nil
        var ok = false
        var finalName = t.name
        if let reader = try? FileHandle(forReadingFrom: t.part) {
            var hasher = SHA256()
            while let data = try? reader.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
            try? reader.close()
            ok = hasher.finalize().map { String(format: "%02x", $0) }.joined() == t.sha256
        }
        if ok { if let saved = saveToDownloads(t.part, t.name) { finalName = saved } else { ok = false } }
        try? FileManager.default.removeItem(at: t.part)
        finished.append(t.id)
        if finished.count > 128 { finished.removeFirst() }
        onChanged(FileTransferInfo(transferId: t.id, peerId: t.peerId, name: finalName, size: t.size, outgoing: false, state: ok ? "done" : "failed", bytes: ok ? t.size : 0))
        var payload: [String: JSONValue] = ["transferId": .string(t.id), "ok": .bool(ok)]
        if !ok { payload["reason"] = .string("hash_mismatch") }
        send(t.peerId, "file.complete", payload)
    }

    private func discard(_ t: Incoming) {
        try? t.handle?.close(); t.handle = nil
        try? FileManager.default.removeItem(at: t.part)
    }

    private func onAccept(_ sender: String, _ id: String, _ p: JSONValue) {
        guard let t = outgoing[id], t.peerId == sender, Self.active.contains(t.state), t.size > 0 else { return }
        let next = min(max(p["next"]?.numberValue.map(Int.init) ?? 0, 0), FileTransferRules.chunkCount(size: t.size))
        startSending(t, from: next) // a duplicate accept restarts from the same index
    }

    private func onReject(_ sender: String, _ id: String) {
        guard let t = outgoing[id], t.peerId == sender, t.state != "done", t.state != "cancelled" else { return }
        t.sender?.cancel(); t.state = "rejected"; changed(t)
    }

    private func onComplete(_ sender: String, _ id: String, _ p: JSONValue) {
        guard let t = outgoing[id], t.peerId == sender, t.state != "done", t.state != "cancelled" else { return }
        t.sender?.cancel()
        if case .bool(true)? = p["ok"] { t.state = "done"; t.sent = t.size } else { t.state = "failed" }
        changed(t)
    }

    private func onCancel(_ sender: String, _ id: String) {
        if let i = incoming[id], i.peerId == sender {
            incoming[id] = nil; i.promptTimeout?.cancel(); discard(i)
            onChanged(FileTransferInfo(transferId: id, peerId: sender, name: i.name, size: i.size, outgoing: false, state: "cancelled", bytes: 0))
        }
        if let t = outgoing[id], t.peerId == sender, Self.active.contains(t.state) { t.sender?.cancel(); t.state = "cancelled"; changed(t) }
    }

    // MARK: helpers

    // Not being connected is normal (the peer left): the reconcile paths try again, so a failed send is not an error.
    private func send(_ peer: String, _ type: String, _ payload: [String: JSONValue]) {
        let envelope = Envelope(type: type, senderId: selfId, recipientId: peer, payload: .object(payload))
        try? sendEnvelope(envelope, nil)
    }

    private func changed(_ t: Outgoing) {
        onChanged(FileTransferInfo(transferId: t.id, peerId: t.peerId, name: t.name, size: t.size, outgoing: true, state: t.state, bytes: t.sent))
    }

    private func incomingChanged(_ t: Incoming) {
        let bytes = min(Int64(t.received.count) * Int64(t.chunkSize), t.size)
        onChanged(FileTransferInfo(transferId: t.id, peerId: t.peerId, name: t.name, size: t.size, outgoing: false, state: t.accepted ? "receiving" : "offered", bytes: bytes))
    }
}
