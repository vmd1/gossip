package dev.vmd1.gossip.features.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class RicherNotificationPayloadTest {
    private fun base() = NotificationPostedPayload(
        id = "k", appPackage = "p", appName = "App", title = "t", body = "b", hasReplyAction = false, timestamp = 1L
    )

    @Test fun aPlainNotificationCarriesNoNewFields() {
        val p = base().toEnvelope("phone").payload
        for (k in listOf("avatarBase64", "pictureBase64", "actions", "smartReplies", "live")) assertFalse(k, p.containsKey(k))
    }

    @Test fun richFieldsAreEncodedWhenPresent() {
        val p = base().copy(
            avatarBase64 = "AA==", actions = listOf(NotificationActionInfo(1, "Archive")), smartReplies = listOf("Ok", "No"),
            live = NotificationLive("progress", progress = 3, max = 10)
        ).toEnvelope("phone").payload
        assertEquals("AA==", p["avatarBase64"]!!.jsonPrimitive.content)
        assertEquals("Archive", p["actions"]!!.toString().let { Regex("\"title\":\"(.*?)\"").find(it)!!.groupValues[1] })
        assertEquals("progress", p["live"]!!.jsonObject["kind"]!!.jsonPrimitive.content)
        assertFalse(p["live"]!!.jsonObject.containsKey("indeterminate"))
    }

    @Test fun anActionAttemptIsHandledOnce() {
        val r = RecentAttempts(limit = 2)
        assertTrue(r.firstTime("a")); assertFalse(r.firstTime("a"))
        assertTrue(r.firstTime("b")); assertTrue(r.firstTime("c"))
        assertTrue("evicted entries may repeat, the cache is bounded", r.firstTime("a"))
    }
}
