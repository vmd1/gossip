package dev.vmd1.gossip.features.screenmirror

import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Start/stop idempotency + failure paths of [ScreenMirrorState], with a fake capture session. */
class ScreenMirrorStateTest {
    private class FakeSession(override val sessionId: String, val failStart: Boolean = false) : ScreenSession {
        @Volatile var started = 0
        @Volatile var closed = 0
        override fun start(): ScreenSession.Ready {
            started++
            if (failStart) error("boom")
            return ScreenSession.Ready(1234, "secret-$sessionId", 576, 1280, "h264")
        }
        override fun close() { closed++ }
    }

    private val sent = CopyOnWriteArrayList<Envelope>()
    private val sessions = CopyOnWriteArrayList<FakeSession>()
    private var shizuku = true
    private var failStart = false
    private var screenEnabled = true
    private var screenOffEnabled = false

    private val prepared = CopyOnWriteArrayList<String>()
    private val capturedOptions = CopyOnWriteArrayList<ScrcpyServerSession.Options>()

    private fun state() = ScreenMirrorState(
        selfId = "phone",
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        shizukuReady = { shizuku },
        send = { sent.add(it) },
        sessionFactory = { id, options, _ -> capturedOptions.add(options); FakeSession(id, failStart).also { sessions.add(it) } },
        appLister = { listOf(ScreenMirrorState.AppInfo("com.example.notes", "Notes", 5L), ScreenMirrorState.AppInfo("org.demo.maps", "Maps", 9L)) },
        iconProvider = { byteArrayOf(1, 2, 3) },
        appChecker = { pkg -> if (pkg == "com.example.gone") "app_unavailable" else null },
        prepareApp = { pkg -> prepared.add(pkg); if (pkg == "com.example.stuck") "app_enable_failed" else null },
        warn = { _, _ -> },
        isEnabled = { screenEnabled },
        screenOffEnabled = { screenOffEnabled },
    )

    private fun env(type: String, sessionId: String? = null) = Envelope(
        type = type, senderId = "mac", recipientId = "phone",
        payload = buildJsonObject { sessionId?.let { put("sessionId", JsonPrimitive(it)) } }
    )

    private fun awaitSent(n: Int) {
        val end = System.currentTimeMillis() + 3000
        while (sent.size < n && System.currentTimeMillis() < end) Thread.sleep(10)
    }

    @Test fun startLaunchesOnceAndRepliesReady() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals(1, sessions.size)
        assertEquals(MessageType.SCREEN_READY, sent[0].type)
        assertEquals("mac", sent[0].recipientId)
        assertEquals("secret-a", sent[0].payload["secret"]!!.jsonPrimitive.content)
        assertTrue(s.isMirroring.value)
    }

    @Test fun duplicateStartDoesNotRelaunchButResendsReady() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(2)
        assertEquals(1, sessions.size)
        assertEquals(1, sessions[0].started)
        assertEquals(2, sent.count { it.type == MessageType.SCREEN_READY })
        assertEquals(0, sessions[0].closed)
    }

    @Test fun duplicateAndUnknownStopsAreNoOps() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "other"))
        assertTrue(s.isMirroring.value)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        Thread.sleep(200)
        assertFalse(s.isMirroring.value)
        assertEquals(1, sessions[0].closed)
    }

    @Test fun lateDuplicateStartAfterStopDoesNotResurrect() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        Thread.sleep(200)
        assertEquals(1, sessions.size)
        assertFalse(s.isMirroring.value)
    }

    @Test fun stopBeforeStartIsRememberedToo() {
        val s = state()
        s.onScreenStop(env(MessageType.SCREEN_STOP, "a"))
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        Thread.sleep(200)
        assertEquals(0, sessions.size)
    }

    @Test fun newSessionSupersedesOld() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStart(env(MessageType.SCREEN_START, "b"))
        awaitSent(2)
        Thread.sleep(200)
        assertEquals(2, sessions.size)
        assertEquals(1, sessions[0].closed)
        assertEquals(0, sessions[1].closed)
        assertTrue(s.isMirroring.value)
    }

    @Test fun shizukuUnavailableRepliesError() {
        shizuku = false
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals(MessageType.SCREEN_ERROR, sent[0].type)
        assertEquals("shizuku_unavailable", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(0, sessions.size)
        assertFalse(s.isMirroring.value)
    }

    @Test fun captureStartFailureRepliesErrorAndCleansUp() {
        failStart = true
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals("capture_failed", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(1, sessions[0].closed)
        assertFalse(s.isMirroring.value)
    }

    @Test fun messagesWithoutSessionIdAreIgnored() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START))
        Thread.sleep(100)
        assertEquals(0, sessions.size)
        assertFalse(s.isMirroring.value)
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        s.onScreenStop(env(MessageType.SCREEN_STOP)) // no sessionId: must not end the active session
        assertTrue(s.isMirroring.value)
        assertEquals(0, sessions[0].closed)
    }

    @Test fun featureTurnedOffRefusesWithoutLaunchingAnything() {
        screenEnabled = false
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertEquals(MessageType.SCREEN_ERROR, sent[0].type)
        assertEquals("feature_disabled", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals("mac", sent[0].recipientId)
        assertEquals(0, sessions.size)
        assertFalse(s.isMirroring.value)

        screenEnabled = true // turning it back on lets the same viewer try again
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(2)
        assertEquals(MessageType.SCREEN_READY, sent[1].type)
    }

    @Test fun screenOffSettingIsPassedToTheSessionAndReadPerStart() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertFalse(capturedOptions[0].screenOff) // off by default

        screenOffEnabled = true // read at each start, not cached
        s.onScreenStart(env(MessageType.SCREEN_START, "b"))
        awaitSent(2)
        assertTrue(capturedOptions[1].screenOff)
    }

    @Test fun onDeviceStopEndsTheSessionAndClearsTheIndicatorState() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "a"))
        awaitSent(1)
        assertTrue(s.isMirroring.value)

        s.stopActive()
        assertFalse(s.isMirroring.value)
        val end = System.currentTimeMillis() + 3000
        while (sessions[0].closed == 0 && System.currentTimeMillis() < end) Thread.sleep(10)
        assertEquals(1, sessions[0].closed)
        s.stopActive() // nothing active: harmless
        assertFalse(s.isMirroring.value)
    }

    @Test fun appWindowOptionsAreValidatedAndDefaulted() {
        val s = state()
        s.onScreenStart(Envelope(type = MessageType.SCREEN_START, senderId = "mac", recipientId = "phone",
            payload = buildJsonObject { put("sessionId", JsonPrimitive("w")); put("app", JsonPrimitive("com.example.notes")) }))
        awaitSent(1)
        val o = capturedOptions[0]
        assertEquals("com.example.notes", o.startApp)
        assertEquals("1080x2340/420", o.newDisplay)
        assertTrue(o.isAppWindow)
    }

    @Test fun hostileAppOrSizeNeverReachesTheCommandLine() {
        val s = state()
        s.onScreenStart(Envelope(type = MessageType.SCREEN_START, senderId = "mac", recipientId = "phone",
            payload = buildJsonObject { put("sessionId", JsonPrimitive("x")); put("app", JsonPrimitive("a.b; rm -rf /")) }))
        awaitSent(1)
        assertEquals(null, capturedOptions[0].startApp)
        assertEquals(null, capturedOptions[0].newDisplay)
        assertFalse(capturedOptions[0].isAppWindow)
        assertFalse(ScrcpyServerSession.Options.isValidDisplaySpec("1080x2340/420 && id"))
        assertTrue(ScrcpyServerSession.Options.isValidDisplaySpec("1080x2340/420"))
        assertFalse(ScrcpyServerSession.Options.isValidPackage("nodots"))
    }

    @Test fun appsRequestListsAppsAndIsRepeatable() {
        val s = state()
        val req = env(MessageType.SCREEN_APPS_REQUEST)
        s.onAppsRequest(req); s.onAppsRequest(req)
        awaitSent(2)
        assertEquals(2, sent.count { it.type == MessageType.SCREEN_APPS })
        assertEquals(sent[0].payload, sent[1].payload)
        assertEquals(2, (sent[0].payload["apps"] as kotlinx.serialization.json.JsonArray).size)
        assertEquals("a query never starts capture", 0, sessions.size)
    }

    @Test fun appsRequestIsRefusedWhenMirroringIsOff() {
        screenEnabled = false
        val s = state()
        s.onAppsRequest(env(MessageType.SCREEN_APPS_REQUEST))
        awaitSent(1)
        assertEquals(0, (sent[0].payload["apps"] as kotlinx.serialization.json.JsonArray).size)
        assertEquals("feature_disabled", sent[0].payload["reason"]!!.jsonPrimitive.content)
    }

    private fun appStart(id: String, pkg: String) = Envelope(type = MessageType.SCREEN_START, senderId = "mac", recipientId = "phone",
        payload = buildJsonObject { put("sessionId", JsonPrimitive(id)); put("app", JsonPrimitive(pkg)) })

    @Test fun appWindowsRunSideBySideAndDontEndTheWholeScreenMirror() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "full"))
        s.onScreenStart(appStart("a1", "com.example.one"))
        s.onScreenStart(appStart("a2", "com.example.two"))
        awaitSent(3)
        assertEquals(3, sessions.size)
        assertTrue(sessions.all { it.closed == 0 })
    }

    @Test fun onlyAWholeScreenMirrorCountsAsSomeoneViewingThePhone() {
        val s = state()
        s.onScreenStart(appStart("a1", "com.example.one"))
        awaitSent(1)
        assertFalse(s.isMirroring.value) // an app window is on a separate virtual display, not this screen
        s.onScreenStart(env(MessageType.SCREEN_START, "full"))
        awaitSent(2)
        assertTrue(s.isMirroring.value)
    }

    @Test fun aNewWholeScreenMirrorReplacesOnlyTheOldWholeScreenMirror() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "f1"))
        s.onScreenStart(appStart("a1", "com.example.one"))
        s.onScreenStart(env(MessageType.SCREEN_START, "f2"))
        awaitSent(3)
        Thread.sleep(100)
        assertEquals(1, sessions[0].closed); assertEquals(0, sessions[1].closed); assertEquals(0, sessions[2].closed)
    }

    @Test fun theOldestAppWindowMakesRoomPastTheLimit() {
        val s = state()
        repeat(ScreenMirrorState.MAX_APP_WINDOWS + 1) { s.onScreenStart(appStart("a$it", "com.example.app$it")) }
        awaitSent(ScreenMirrorState.MAX_APP_WINDOWS + 1)
        Thread.sleep(100)
        assertEquals(1, sessions[0].closed)
        assertEquals(0, sessions[1].closed)
    }

    @Test fun anUninstalledAppIsRefusedWithAReasonAndStartsNothing() {
        val s = state()
        s.onScreenStart(appStart("x", "com.example.gone"))
        awaitSent(1)
        assertEquals("app_unavailable", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(0, sessions.size)
        assertTrue(prepared.isEmpty())
    }

    @Test fun anAppIsPreparedBeforeItsSessionStarts() {
        val s = state()
        s.onScreenStart(appStart("p", "com.example.sleepy"))
        awaitSent(1)
        assertEquals(listOf("com.example.sleepy"), prepared.toList())
        assertEquals(MessageType.SCREEN_READY, sent[0].type)
    }

    @Test fun anAppThatCantBeEnabledIsReportedAndStartsNothing() {
        val s = state()
        s.onScreenStart(appStart("q", "com.example.stuck"))
        awaitSent(1)
        assertEquals("app_enable_failed", sent[0].payload["reason"]!!.jsonPrimitive.content)
        assertEquals(0, sessions.size)
    }

    @Test fun aWholeScreenMirrorPreparesNoApp() {
        val s = state()
        s.onScreenStart(env(MessageType.SCREEN_START, "w"))
        awaitSent(1)
        assertTrue(prepared.isEmpty())
    }

    @Test fun onlyMissingOrChangedIconsAreSent() {
        val s = state()
        val have = kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("com.example.notes@5"), JsonPrimitive("org.demo.maps@8")))
        s.onAppsRequest(Envelope(type = MessageType.SCREEN_APPS_REQUEST, senderId = "mac", recipientId = "phone",
            payload = buildJsonObject { put("icons", JsonPrimitive(true)); put("haveIcons", have) }))
        awaitSent(2)
        val icons = sent.first { it.type == MessageType.SCREEN_APP_ICONS }.payload["icons"] as kotlinx.serialization.json.JsonArray
        assertEquals("Notes is unchanged, Maps was updated", 1, icons.size)
        assertEquals("org.demo.maps", (icons[0] as kotlinx.serialization.json.JsonObject)["package"]!!.jsonPrimitive.content)
    }

    @Test fun noIconsAreSentWhenTheViewerHasThemAll() {
        val s = state()
        val have = kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("com.example.notes@5"), JsonPrimitive("org.demo.maps@9")))
        s.onAppsRequest(Envelope(type = MessageType.SCREEN_APPS_REQUEST, senderId = "mac", recipientId = "phone",
            payload = buildJsonObject { put("icons", JsonPrimitive(true)); put("haveIcons", have) }))
        Thread.sleep(300)
        assertEquals(0, sent.count { it.type == MessageType.SCREEN_APP_ICONS })
    }
}
