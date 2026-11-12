package dev.vmd1.gossip.features.filetransfer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The shared cases (`schema/file-transfer-cases.json`) the Mac rules pass too. */
class FileTransferRulesTest {
    private val cases by lazy {
        val file = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "schema/file-transfer-cases.json") }.first { it.exists() }
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    @Test fun sanitize() {
        val list = cases["sanitize"]!!.jsonArray
        assertTrue(list.isNotEmpty())
        for (c in list.map { it.jsonObject }) {
            val raw = c["raw"]!!.jsonPrimitive.content
            assertEquals(raw, c["name"]!!.jsonPrimitive.content, FileTransferRules.sanitizeName(raw))
        }
    }

    @Test fun uniqueNames() {
        for (c in cases["unique"]!!.jsonArray.map { it.jsonObject }) {
            val taken = c["taken"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
            assertEquals(c["result"]!!.jsonPrimitive.content, FileTransferRules.uniqueName(c["name"]!!.jsonPrimitive.content) { it in taken })
        }
    }

    @Test fun chunks() {
        for (c in cases["chunks"]!!.jsonArray.map { it.jsonObject }) {
            val size = c["size"]!!.jsonPrimitive.long
            val chunk = c["chunkSize"]!!.jsonPrimitive.int
            val count = FileTransferRules.chunkCount(size, chunk)
            assertEquals(c["count"]!!.jsonPrimitive.int, count)
            if (count > 0) assertEquals(c["lastLength"]!!.jsonPrimitive.int, FileTransferRules.chunkLength(size, chunk, count - 1))
        }
    }

    @Test fun resume() {
        for (c in cases["resume"]!!.jsonArray.map { it.jsonObject }) {
            val received = c["received"]!!.jsonArray.map { it.jsonPrimitive.int }.toSet()
            assertEquals(c["next"]!!.jsonPrimitive.int, FileTransferRules.nextIndex(received))
        }
    }

    @Test fun longNamesKeepTheirExtension() {
        val name = FileTransferRules.sanitizeName("a".repeat(300) + ".pdf")
        assertEquals(FileTransferRules.MAX_NAME_LENGTH, name.length)
        assertTrue(name.endsWith(".pdf"))
    }
}
