package com.connect.features.filetransfer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import com.connect.crypto.IdentityKeyStore
import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "FileTransferManager"

/**
 * Sends and receives files over the existing encrypted transport (see
 * `schema/message-types.md` for the `file.offer` / `file.accept` / `file.reject` /
 * `file.complete` message types and the `file.chunk` raw-frame convention).
 *
 * - Sending: [sendFile] reads a `content://` [Uri] delivered by Android's share sheet
 *   (`ACTION_SEND`/`ACTION_SEND_MULTIPLE`, see `AndroidManifest.xml`) via
 *   [android.content.ContentResolver], sends `file.offer`, awaits `file.accept`, then
 *   streams 256 KiB chunks followed by `file.complete` carrying a SHA-256 of the whole
 *   file.
 * - Receiving: registers a [MessageRouter] handler for `file.offer`. v1 auto-accepts
 *   every offer and persists incoming chunks via the Storage Access Framework
 *   (`MediaStore.Downloads`, scoped storage — no broad storage permission needed) into
 *   a "Connect Received Files" collection, verifying the SHA-256 on `file.complete`
 *   before the entry is taken out of its pending state.
 */
class FileTransferManager(
    private val context: Context,
    private val identityKeyStore: IdentityKeyStore,
    private val transportManager: TransportManager,
    private val messageRouter: MessageRouter
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val pendingAccepts = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()
    private val incomingTransfers = ConcurrentHashMap<String, IncomingTransfer>()

    private class IncomingTransfer(
        val transferId: String,
        val displayName: String,
        val uri: Uri,
        val outputStream: OutputStream,
        val hasher: IncrementalSha256 = IncrementalSha256()
    )

    init {
        messageRouter.register(MessageType.FILE_OFFER, EnvelopeHandler { handleOffer(it) })
        messageRouter.register(MessageType.FILE_ACCEPT, EnvelopeHandler { handleAcceptOrReject(it, accepted = true) })
        messageRouter.register(MessageType.FILE_REJECT, EnvelopeHandler { handleAcceptOrReject(it, accepted = false) })
        messageRouter.register(MessageType.FILE_CHUNK, EnvelopeHandler { handleChunkMetadata(it) })
        messageRouter.register(MessageType.FILE_COMPLETE, EnvelopeHandler { handleComplete(it) })
    }

    fun shutdown() {
        scope.cancel()
    }

    // region Sending

    /** Reads [uri] (from a share-sheet intent) via [android.content.ContentResolver]
     *  and sends it to the connected peer. */
    suspend fun sendFile(uri: Uri) {
        val resolver = context.contentResolver
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("Could not open $uri")

        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIdx >= 0 && cursor.moveToFirst()) {
                cursor.getString(nameIdx)?.let { name = it }
            }
        }
        val mimeType = resolver.getType(uri) ?: "application/octet-stream"
        send(bytes, name, mimeType)
    }

    /** Sends raw [data] under [name]/[mimeType], awaiting acceptance before streaming chunks. */
    suspend fun send(data: ByteArray, name: String, mimeType: String) {
        val transferId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<Boolean>()
        pendingAccepts[transferId] = deferred

        try {
            transportManager.send(
                Envelope(
                    type = MessageType.FILE_OFFER,
                    senderId = identityKeyStore.deviceId,
                    payload = buildJsonObject {
                        put("transferId", transferId)
                        put("name", name)
                        put("sizeBytes", data.size)
                        put("mimeType", mimeType)
                    }
                )
            )
        } catch (e: Exception) {
            pendingAccepts.remove(transferId)
            throw e
        }

        val accepted = deferred.await()
        if (!accepted) {
            throw IllegalStateException("Transfer $transferId was rejected by the peer")
        }

        val chunks = FileChunker.chunks(data)
        chunks.forEachIndexed { index, chunk ->
            transportManager.send(
                Envelope(
                    type = MessageType.FILE_CHUNK,
                    senderId = identityKeyStore.deviceId,
                    payload = buildJsonObject {
                        put("transferId", transferId)
                        put("chunkIndex", index)
                        put("byteLength", chunk.size)
                    }
                )
            )
            transportManager.sendRawFrame(chunk)
        }

        transportManager.send(
            Envelope(
                type = MessageType.FILE_COMPLETE,
                senderId = identityKeyStore.deviceId,
                payload = buildJsonObject {
                    put("transferId", transferId)
                    put("sha256", FileChunker.sha256Hex(data))
                }
            )
        )
    }

    // endregion

    // region Receiving

    private fun handleOffer(envelope: Envelope) {
        val transferId = envelope.payload.stringField("transferId") ?: return
        val name = envelope.payload.stringField("name") ?: "file"
        val mimeType = envelope.payload.stringField("mimeType") ?: "application/octet-stream"

        val uri = createDestination(name, mimeType)
        if (uri == null) {
            Log.w(TAG, "Could not create destination for incoming transfer $transferId")
            return
        }
        val out = runCatching { context.contentResolver.openOutputStream(uri) }.getOrNull()
        if (out == null) {
            Log.w(TAG, "Could not open output stream for incoming transfer $transferId")
            return
        }

        incomingTransfers[transferId] = IncomingTransfer(transferId, name, uri, out)

        // v1: auto-accept every incoming offer (see schema/message-types.md).
        scope.launch {
            runCatching {
                transportManager.send(
                    Envelope(
                        type = MessageType.FILE_ACCEPT,
                        senderId = identityKeyStore.deviceId,
                        payload = buildJsonObject { put("transferId", transferId) }
                    )
                )
            }.onFailure { Log.w(TAG, "Failed to send file.accept for $transferId", it) }
        }
    }

    private fun handleAcceptOrReject(envelope: Envelope, accepted: Boolean) {
        val transferId = envelope.payload.stringField("transferId") ?: return
        pendingAccepts.remove(transferId)?.complete(accepted)
    }

    private fun handleChunkMetadata(envelope: Envelope) {
        val transferId = envelope.payload.stringField("transferId") ?: return
        // Arms the transport's one-shot raw-frame handler; per the `file.chunk`
        // convention this metadata envelope is always immediately followed by
        // exactly one raw binary frame.
        transportManager.setPendingRawFrameHandler { bytes -> handleChunkData(transferId, bytes) }
    }

    private fun handleChunkData(transferId: String, bytes: ByteArray) {
        val transfer = incomingTransfers[transferId] ?: return
        runCatching {
            transfer.outputStream.write(bytes)
            transfer.hasher.update(bytes)
        }.onFailure { Log.w(TAG, "Failed writing chunk for $transferId", it) }
    }

    private fun handleComplete(envelope: Envelope) {
        val transferId = envelope.payload.stringField("transferId") ?: return
        val expectedHex = envelope.payload.stringField("sha256") ?: return
        val transfer = incomingTransfers.remove(transferId) ?: return

        runCatching { transfer.outputStream.flush(); transfer.outputStream.close() }

        val actualHex = transfer.hasher.hex()
        val resolver = context.contentResolver

        if (!actualHex.equals(expectedHex, ignoreCase = true)) {
            Log.w(TAG, "File transfer $transferId failed checksum verification, discarding")
            runCatching { resolver.delete(transfer.uri, null, null) }
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            runCatching { resolver.update(transfer.uri, values, null, null) }
        }
    }

    /** Inserts a new, initially-pending entry into the "Connect Received Files"
     *  collection under Downloads, returning its content [Uri]. */
    private fun createDestination(name: String, mimeType: String): Uri? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Connect Received Files")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Downloads.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Files.getContentUri("external")
        }
        return runCatching { resolver.insert(collection, values) }.getOrNull()
    }

    // endregion
}

private fun JsonObject.stringField(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
