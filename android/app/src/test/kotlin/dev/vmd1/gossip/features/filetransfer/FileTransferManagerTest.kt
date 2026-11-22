package dev.vmd1.gossip.features.filetransfer

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.transport.MessageRouter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/** Two managers wired back to back through an in-memory "network": the whole offer, accept, chunk, complete exchange. */
class FileTransferManagerTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val tmp = Files.createTempDirectory("ft").toFile()
    @After fun cleanup() { scope.cancel(); tmp.deleteRecursively() }

    private class FileSrc(private val f: File) : FileSource {
        override val name = f.name
        override val size = f.length()
        override fun open(): InputStream = f.inputStream()
        override fun read(offset: Long, length: Int): ByteArray { RandomAccessFile(f, "r").use { r -> r.seek(offset); return ByteArray(length).also { r.readFully(it) } } }
    }

    private class Side(val id: String, val router: MessageRouter = MessageRouter()) {
        lateinit var manager: FileTransferManager
        val saved = CopyOnWriteArrayList<Pair<String, ByteArray>>()
        val changes = CopyOnWriteArrayList<TransferInfo>()
        val offers = CopyOnWriteArrayList<IncomingOffer>()
    }

    private fun pair(connected: AtomicBoolean = AtomicBoolean(true), autoAccept: Boolean = true, dropChunks: AtomicBoolean = AtomicBoolean(false)): Pair<Side, Side> {
        val a = Side("a"); val b = Side("b")
        fun build(me: Side, other: () -> Side) {
            me.manager = FileTransferManager(
                messageRouter = me.router, scope = scope, selfId = me.id, partDir = File(tmp, "${me.id}-parts"),
                sendEnvelope = { env, raw ->
                    if (!connected.get()) error("Not connected")
                    if (raw != null && dropChunks.get()) return@FileTransferManager
                    val o = other()
                    if (raw != null) o.manager.onRawChunk(env, raw) else o.router.dispatch(env)
                },
                isConnected = { connected.get() }, pendingOutboundBytes = { 0 }, peerName = { "peer" },
                saveToDownloads = { part, name -> me.saved.add(name to part.readBytes()); name },
                freeSpace = { Long.MAX_VALUE },
                onOffer = { offer -> me.offers.add(offer); if (autoAccept && me === b) me.manager.respond(offer.transferId, true) },
                onChanged = { me.changes.add(it) },
                reofferEveryMs = 150
            )
            me.manager.start()
        }
        build(a) { b }; build(b) { a }
        return a to b
    }

    private fun randomFile(size: Int): File = File(tmp, "src.bin").also { f -> f.writeBytes(ByteArray(size).also { java.util.Random(7).nextBytes(it) }) }

    private fun await(what: String, cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) delay(20) } }

    @Test fun aFileGoesThroughIntact() {
        val (a, b) = pair()
        val src = randomFile(5 * 1024 * 1024 + 123)
        runBlocking { a.manager.sendFile("b", FileSrc(src)) }
        await("received") { b.saved.isNotEmpty() }
        assertEquals("src.bin", b.saved[0].first)
        assertArrayEquals(src.readBytes(), b.saved[0].second)
        await("sender done") { a.changes.any { it.state == "done" } }
        assertEquals(1, b.saved.size)
    }

    @Test fun anEmptyFileStillCompletes() {
        val (a, b) = pair()
        val src = randomFile(0)
        runBlocking { a.manager.sendFile("b", FileSrc(src)) }
        await("received") { b.saved.isNotEmpty() }
        assertEquals(0, b.saved[0].second.size)
    }

    @Test fun decliningRejectsAndSavesNothing() {
        val (a, b) = pair(autoAccept = false)
        runBlocking { a.manager.sendFile("b", FileSrc(randomFile(2048))) }
        await("offer") { b.offers.isNotEmpty() }
        b.manager.respond(b.offers[0].transferId, false)
        await("rejected") { a.changes.any { it.state == "rejected" } }
        assertTrue(b.saved.isEmpty())
    }

    @Test fun theOfferIsNotShownTwiceWhenItIsResent() {
        val (a, b) = pair(autoAccept = false)
        runBlocking { a.manager.sendFile("b", FileSrc(randomFile(2048))) }
        await("offer") { b.offers.isNotEmpty() }
        runBlocking { delay(600) } // the sender re-offers every 150 ms while unanswered
        assertEquals(1, b.offers.size)
    }

    @Test fun aDuplicateChunkIsHarmless() {
        val (a, b) = pair()
        val src = randomFile(3 * 1024 * 1024)
        runBlocking { a.manager.sendFile("b", FileSrc(src)) }
        await("received") { b.saved.isNotEmpty() }
        val id = a.changes.first().transferId
        // A late duplicate of a finished transfer's chunk and offer changes nothing and does not prompt again.
        b.manager.onRawChunk(Envelope(type = "file.chunk", senderId = "a", payload = kotlinx.serialization.json.buildJsonObject { put("transferId", kotlinx.serialization.json.JsonPrimitive(id)); put("index", kotlinx.serialization.json.JsonPrimitive(0)) }), ByteArray(1024 * 1024))
        runBlocking { delay(300) }
        assertEquals(1, b.saved.size)
        assertEquals(1, b.offers.size)
    }

    @Test fun aDroppedConnectionResumesFromWhereItStopped() {
        val connected = AtomicBoolean(true)
        val (a, b) = pair(connected)
        val src = randomFile(8 * 1024 * 1024)
        runBlocking { a.manager.sendFile("b", FileSrc(src)) }
        await("some chunks") { b.changes.any { it.state == "receiving" && it.bytes >= 1024 * 1024 } }
        connected.set(false)
        runBlocking { delay(300) }
        connected.set(true)
        a.manager.onPeerConnected("b")
        await("received") { b.saved.isNotEmpty() }
        assertArrayEquals(src.readBytes(), b.saved[0].second)
        assertFalse(b.saved.size > 1)
    }
}
