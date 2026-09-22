import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Drag-and-drop file transfer to/from the paired Android device, over the
/// existing encrypted transport (see `schema/message-types.md` for the
/// `file.offer` / `file.accept` / `file.reject` / `file.complete` message
/// types and the `file.chunk` raw-frame convention).
///
/// - Sending: `sendFile(at:)` reads a dropped file, sends `file.offer`,
///   awaits `file.accept`, then streams 256 KiB chunks followed by
///   `file.complete` carrying a SHA-256 of the whole file.
/// - Receiving: registers a `MessageRouter` handler for `file.offer`.
///   v1 auto-accepts every offer, writes incoming chunks to a `.part` file
///   under `~/Downloads/Connect Received Files`, and verifies the SHA-256 on
///   `file.complete` before renaming the file into place.
final class FileTransferManager: ObservableObject {
    enum TransferError: Error, Equatable {
        case rejected
        case notConnected
        case couldNotReadFile
    }

    struct TransferProgress: Identifiable, Equatable {
        let id: String
        let name: String
        let sizeBytes: Int
        var bytesTransferred: Int
        var direction: Direction

        enum Direction: Equatable { case sending, receiving }
    }

    /// Keyed by `transferId`. Mac menu-bar UI observes this to show progress;
    /// entries are removed once a transfer completes, fails, or is rejected.
    @Published private(set) var activeTransfers: [String: TransferProgress] = [:]

    private let transportManager: TransportManager
    private let identity: IdentityKeyStore
    let receivedFilesDirectory: URL

    /// Guards `pendingAccepts` and `incomingTransfers`, which are touched
    /// both from the transport's receive queue (router handlers) and from
    /// `Task`s driving outbound sends.
    private let stateLock = NSLock()
    private var pendingAccepts: [String: CheckedContinuation<Bool, Never>] = [:]
    private var incomingTransfers: [String: IncomingTransfer] = [:]

    private final class IncomingTransfer {
        let transferId: String
        let name: String
        let sizeBytes: Int
        let partURL: URL
        let finalURL: URL
        let handle: FileHandle
        var hasher = SHA256()
        var bytesWritten = 0

        init(transferId: String, name: String, sizeBytes: Int, partURL: URL, finalURL: URL, handle: FileHandle) {
            self.transferId = transferId
            self.name = name
            self.sizeBytes = sizeBytes
            self.partURL = partURL
            self.finalURL = finalURL
            self.handle = handle
        }
    }

    init(transportManager: TransportManager, identity: IdentityKeyStore = .shared) {
        self.transportManager = transportManager
        self.identity = identity

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        self.receivedFilesDirectory = downloads.appendingPathComponent("Connect Received Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: receivedFilesDirectory, withIntermediateDirectories: true)

        registerHandlers()
    }

    // MARK: - Sending

    /// Reads `fileURL` (e.g. from a drag-and-drop `NSItemProvider`) and
    /// sends it to the connected peer.
    func sendFile(at fileURL: URL) async throws {
        guard let data = try? Data(contentsOf: fileURL) else { throw TransferError.couldNotReadFile }
        let name = fileURL.lastPathComponent
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        try await send(data: data, name: name, mimeType: mimeType)
    }

    /// Sends raw `data` under `name`/`mimeType`, awaiting acceptance before
    /// streaming chunks. Throws `TransferError.rejected` if the peer sends
    /// `file.reject`, or `TransferError.notConnected` if the offer can't be
    /// sent at all.
    func send(data: Data, name: String, mimeType: String) async throws {
        let transferId = UUID().uuidString

        setTransfer(TransferProgress(id: transferId, name: name, sizeBytes: data.count, bytesTransferred: 0, direction: .sending))

        let offer = Envelope(
            type: "file.offer",
            senderId: identity.deviceId,
            payload: .object([
                "transferId": .string(transferId),
                "name": .string(name),
                "sizeBytes": .number(Double(data.count)),
                "mimeType": .string(mimeType)
            ])
        )

        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            stateLock.lock()
            pendingAccepts[transferId] = continuation
            stateLock.unlock()
            do {
                try transportManager.send(envelope: offer)
            } catch {
                stateLock.lock()
                let pending = pendingAccepts.removeValue(forKey: transferId)
                stateLock.unlock()
                pending?.resume(returning: false)
            }
        }

        guard accepted else {
            clearTransfer(transferId)
            throw TransferError.rejected
        }

        do {
            let chunks = FileChunker.chunks(for: data)
            for (index, chunk) in chunks.enumerated() {
                let meta = Envelope(
                    type: "file.chunk",
                    senderId: identity.deviceId,
                    payload: .object([
                        "transferId": .string(transferId),
                        "chunkIndex": .number(Double(index)),
                        "byteLength": .number(Double(chunk.count))
                    ])
                )
                try transportManager.send(envelope: meta)
                try transportManager.sendRawFrame(chunk)
                updateBytesTransferred(transferId, bytes: (index + 1 == chunks.count) ? data.count : min(data.count, (index + 1) * FileChunker.chunkSize))
            }

            let complete = Envelope(
                type: "file.complete",
                senderId: identity.deviceId,
                payload: .object([
                    "transferId": .string(transferId),
                    "sha256": .string(FileChunker.sha256Hex(of: data))
                ])
            )
            try transportManager.send(envelope: complete)
        } catch {
            clearTransfer(transferId)
            throw error
        }

        clearTransfer(transferId)
    }

    // MARK: - Receiving

    private func registerHandlers() {
        transportManager.router.register(prefix: "file.offer") { [weak self] envelope in
            self?.handleOffer(envelope)
        }
        transportManager.router.register(prefix: "file.accept") { [weak self] envelope in
            self?.handleAcceptOrReject(envelope, accepted: true)
        }
        transportManager.router.register(prefix: "file.reject") { [weak self] envelope in
            self?.handleAcceptOrReject(envelope, accepted: false)
        }
        transportManager.router.register(prefix: "file.chunk") { [weak self] envelope in
            self?.handleChunkMetadata(envelope)
        }
        transportManager.router.register(prefix: "file.complete") { [weak self] envelope in
            self?.handleComplete(envelope)
        }
    }

    private func handleOffer(_ envelope: Envelope) {
        guard
            let transferId = envelope.payload["transferId"]?.stringValue,
            let rawName = envelope.payload["name"]?.stringValue
        else { return }
        let sizeBytes = Int(envelope.payload["sizeBytes"]?.numberValue ?? 0)

        let name = sanitizedFileName(rawName)
        let partURL = receivedFilesDirectory.appendingPathComponent(transferId + ".part")
        let finalURL = uniqueDestination(for: name)

        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partURL) else { return }

        let transfer = IncomingTransfer(transferId: transferId, name: name, sizeBytes: sizeBytes, partURL: partURL, finalURL: finalURL, handle: handle)
        stateLock.lock()
        incomingTransfers[transferId] = transfer
        stateLock.unlock()

        setTransfer(TransferProgress(id: transferId, name: name, sizeBytes: sizeBytes, bytesTransferred: 0, direction: .receiving))

        // v1: auto-accept every incoming offer (see schema/message-types.md).
        let accept = Envelope(
            type: "file.accept",
            senderId: identity.deviceId,
            payload: .object(["transferId": .string(transferId)])
        )
        try? transportManager.send(envelope: accept)
    }

    private func handleAcceptOrReject(_ envelope: Envelope, accepted: Bool) {
        guard let transferId = envelope.payload["transferId"]?.stringValue else { return }
        stateLock.lock()
        let continuation = pendingAccepts.removeValue(forKey: transferId)
        stateLock.unlock()
        continuation?.resume(returning: accepted)
    }

    private func handleChunkMetadata(_ envelope: Envelope) {
        guard
            let transferId = envelope.payload["transferId"]?.stringValue,
            envelope.payload["byteLength"]?.numberValue != nil
        else { return }

        // Arms the transport's one-shot raw-frame handler; per the
        // `file.chunk` convention this metadata envelope is always
        // immediately followed by exactly one raw binary frame.
        transportManager.pendingRawFrameHandler = { [weak self] data in
            self?.handleChunkData(transferId: transferId, data: data)
        }
    }

    private func handleChunkData(transferId: String, data: Data) {
        stateLock.lock()
        let transfer = incomingTransfers[transferId]
        stateLock.unlock()
        guard let transfer else { return }

        transfer.handle.write(data)
        transfer.hasher.update(data: data)
        transfer.bytesWritten += data.count

        updateBytesTransferred(transferId, bytes: transfer.bytesWritten)
    }

    private func handleComplete(_ envelope: Envelope) {
        guard
            let transferId = envelope.payload["transferId"]?.stringValue,
            let expectedHex = envelope.payload["sha256"]?.stringValue
        else { return }

        stateLock.lock()
        let transfer = incomingTransfers.removeValue(forKey: transferId)
        stateLock.unlock()
        guard let transfer else { return }

        try? transfer.handle.close()

        let actualHex = FileChunker.hex(transfer.hasher.finalize())
        defer { clearTransfer(transferId) }

        guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
            NSLog("Connect: file transfer \(transferId) failed checksum verification, discarding")
            try? FileManager.default.removeItem(at: transfer.partURL)
            return
        }

        try? FileManager.default.moveItem(at: transfer.partURL, to: transfer.finalURL)
    }

    // MARK: - Helpers

    private func setTransfer(_ progress: TransferProgress) {
        DispatchQueue.main.async { [weak self] in
            self?.activeTransfers[progress.id] = progress
        }
    }

    private func updateBytesTransferred(_ transferId: String, bytes: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.activeTransfers[transferId]?.bytesTransferred = bytes
        }
    }

    private func clearTransfer(_ transferId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.activeTransfers.removeValue(forKey: transferId)
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\")
        let sanitized = name.components(separatedBy: disallowed).joined(separator: "_")
        return sanitized.isEmpty ? "Connect File" : sanitized
    }

    /// Appends " 2", " 3", ... before the extension if `name` already exists
    /// in `receivedFilesDirectory`, so a receive never silently clobbers an
    /// existing file.
    private func uniqueDestination(for name: String) -> URL {
        var candidate = receivedFilesDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        repeat {
            let candidateName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = receivedFilesDirectory.appendingPathComponent(candidateName)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
