package dev.vmd1.gossip.features.media

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaCommandTest {

    @Test
    fun `parses a play command with no seekMs`() {
        val payload = buildJsonObject { put("action", "play") }
        val command = MediaCommand.fromPayload(payload)
        assertEquals(MediaCommand("play", null), command)
    }

    @Test
    fun `parses a command with a seekMs`() {
        val payload = buildJsonObject {
            put("action", "pause")
            put("seekMs", 4200)
        }
        val command = MediaCommand.fromPayload(payload)
        assertEquals(MediaCommand("pause", 4200), command)
    }

    @Test
    fun `returns null for a missing action`() {
        val payload = buildJsonObject { put("seekMs", 100) }
        assertNull(MediaCommand.fromPayload(payload))
    }

    @Test
    fun `returns null for an unrecognized action`() {
        val payload = buildJsonObject { put("action", "shuffle") }
        assertNull(MediaCommand.fromPayload(payload))
    }

    @Test
    fun `returns null when action is not a string primitive`() {
        val payload = buildJsonObject { put("action", JsonNull) }
        assertNull(MediaCommand.fromPayload(payload))
    }

    @Test
    fun `recognizes all four valid actions`() {
        for (action in listOf("play", "pause", "next", "previous")) {
            val payload = buildJsonObject { put("action", action) }
            assertEquals(action, MediaCommand.fromPayload(payload)?.action)
        }
    }
}

class NowPlayingSnapshotTest {

    @Test
    fun `serializes required fields and omits absent optional artBase64`() {
        val snapshot = NowPlayingSnapshot(
            title = "Song Title",
            artist = "An Artist",
            artBase64 = null,
            isPlaying = true,
            positionMs = 15_000,
            durationMs = 210_000,
            packageName = "com.spotify.music"
        )

        val payload = snapshot.toPayload()

        assertEquals("Song Title", payload["title"]?.toString()?.trim('"'))
        assertEquals("An Artist", payload["artist"]?.toString()?.trim('"'))
        assertEquals(false, payload.containsKey("artBase64"))
        assertEquals("true", payload["isPlaying"].toString())
        assertEquals("15000", payload["positionMs"].toString())
        assertEquals("210000", payload["durationMs"].toString())
        assertEquals("com.spotify.music", payload["packageName"]?.toString()?.trim('"'))
    }

    @Test
    fun `includes artBase64 when present`() {
        val snapshot = NowPlayingSnapshot(
            title = "T",
            artist = "A",
            artBase64 = "aGVsbG8=",
            isPlaying = false,
            positionMs = 0,
            durationMs = 0,
            packageName = "com.google.android.apps.youtube.music"
        )

        val payload = snapshot.toPayload()

        assertEquals(true, payload.containsKey("artBase64"))
        assertEquals("aGVsbG8=", payload["artBase64"]?.toString()?.trim('"'))
    }
}

class SelectMostRelevantTest {

    @Test
    fun `prefers the first candidate matching the predicate`() {
        val candidates = listOf("idle-1", "playing", "idle-2")
        val chosen = MediaControlBridge.selectMostRelevant(candidates) { it == "playing" }
        assertEquals("playing", chosen)
    }

    @Test
    fun `falls back to the first candidate when none match`() {
        val candidates = listOf("idle-1", "idle-2")
        val chosen = MediaControlBridge.selectMostRelevant(candidates) { it == "playing" }
        assertEquals("idle-1", chosen)
    }

    @Test
    fun `returns null for an empty list`() {
        val chosen = MediaControlBridge.selectMostRelevant(emptyList<String>()) { true }
        assertNull(chosen)
    }
}
