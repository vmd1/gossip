package dev.vmd1.gossip.features.media

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.gossip_ffi.CommandGuard
import uniffi.gossip_ffi.MediaAction

/** `media.command` validation and de-duplication are the core's `CommandGuard`; these check them across the bindings. */
class MediaCommandTest {
    private fun accept(guard: CommandGuard, json: String) = guard.accept(json)

    @Test
    fun `accepts a play command with no seekMs`() {
        val c = accept(CommandGuard(), """{"action":"play"}""")!!
        assertEquals(MediaAction.PLAY, c.action)
        assertNull(c.seekMs)
    }

    @Test
    fun `accepts a command with a seekMs`() {
        val c = accept(CommandGuard(), """{"action":"pause","seekMs":4200}""")!!
        assertEquals(MediaAction.PAUSE, c.action)
        assertEquals(4200L, c.seekMs)
    }

    @Test
    fun `refuses a missing, unrecognized or non-string action`() {
        val g = CommandGuard()
        assertNull(accept(g, """{"seekMs":100}"""))
        assertNull(accept(g, """{"action":"shuffle"}"""))
        assertNull(accept(g, """{"action":null}"""))
    }

    @Test
    fun `recognizes all four valid actions`() {
        val expected = mapOf("play" to MediaAction.PLAY, "pause" to MediaAction.PAUSE, "next" to MediaAction.NEXT, "previous" to MediaAction.PREVIOUS)
        for ((name, action) in expected) assertEquals(action, accept(CommandGuard(), """{"action":"$name"}""")?.action)
    }

    @Test
    fun `each commandId is acted on once so a duplicate delivery cannot skip twice`() {
        val g = CommandGuard()
        assertEquals(MediaAction.NEXT, accept(g, """{"action":"next","commandId":"abc"}""")?.action)
        assertNull("the same instance again", accept(g, """{"action":"next","commandId":"abc"}"""))
        assertEquals(MediaAction.NEXT, accept(g, """{"action":"next","commandId":"def"}""")?.action)
    }

    @Test
    fun `a command from an older peer without a commandId is still accepted`() {
        val g = CommandGuard()
        assertEquals(MediaAction.NEXT, accept(g, """{"action":"next"}""")?.action)
        assertEquals(MediaAction.NEXT, accept(g, """{"action":"next"}""")?.action)
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
