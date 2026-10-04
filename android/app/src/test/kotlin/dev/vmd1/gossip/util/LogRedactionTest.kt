package dev.vmd1.gossip.util

import org.junit.Assert.assertEquals
import org.junit.Test

class LogRedactionTest {
    @Test
    fun `redacts addresses but leaves ids and times alone`() {
        assertEquals("Connect to <address>:7913 failed", Log.redactAddresses("Connect to 192.168.0.122:7913 failed"))
        assertEquals("peer <address> reset", Log.redactAddresses("peer fe80::1%wlan0 reset"))
        assertEquals("peer <address> reset", Log.redactAddresses("peer 2001:db8:0:0:0:0:0:1 reset"))
        val id = "c4f7555f-b505-4ee1-8d95-963ad5cb39f9"
        assertEquals("device $id at 16:09:44", Log.redactAddresses("device $id at 16:09:44"))
    }
}
