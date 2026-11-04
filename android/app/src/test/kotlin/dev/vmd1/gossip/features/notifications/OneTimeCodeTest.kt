package dev.vmd1.gossip.features.notifications

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The shared cases (`schema/otp-cases.json`) the Mac detector passes too. */
class OneTimeCodeTest {
    @Test fun sharedCases() {
        val file = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "schema/otp-cases.json") }.first { it.exists() }
        val cases = Json.parseToJsonElement(file.readText()).jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val body = c["body"]!!.jsonPrimitive.content
            assertEquals(body, c["code"]!!.jsonPrimitive.contentOrNull, OneTimeCode.detect(c["title"]!!.jsonPrimitive.content, body))
        }
    }
}
