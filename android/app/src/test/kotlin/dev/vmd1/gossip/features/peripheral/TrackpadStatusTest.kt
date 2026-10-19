package dev.vmd1.gossip.features.peripheral

import kotlinx.serialization.json.Json
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackpadStatusTest {
    private fun status(json: String) = Json.parseToJsonElement(json)

    @Test fun `all good gives no problem`() {
        assertNull(TrackpadStatus.problem("Mac", true, status("""{"enabled":true,"accessibility":true}""")))
    }

    @Test fun `feature off and missing permission are explained`() {
        assertTrue(TrackpadStatus.problem("Mac", true, status("""{"enabled":false,"accessibility":true}"""))!!.contains("turned off"))
        assertTrue(TrackpadStatus.problem("Mac", true, status("""{"enabled":true,"accessibility":false}"""))!!.contains("Accessibility"))
    }

    @Test fun `not connected and unknown status are explained`() {
        assertTrue(TrackpadStatus.problem("Mac", false, null)!!.contains("isn't connected"))
        assertTrue(TrackpadStatus.problem("Mac", true, null)!!.contains("Update Gossip"))
    }
}
