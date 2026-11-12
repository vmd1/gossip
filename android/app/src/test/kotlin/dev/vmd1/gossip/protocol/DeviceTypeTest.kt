package dev.vmd1.gossip.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceTypeTest {
    @Test fun `desktop types round trip`() {
        assertEquals(DeviceType.WINDOWS, DeviceType.fromWire("windows"))
        assertEquals(DeviceType.LINUX, DeviceType.fromWire("linux"))
        assertEquals("windows", DeviceType.WINDOWS.wireValue)
    }

    @Test fun `an unknown type never fails and shows as a phone`() {
        assertEquals(DeviceType.ANDROID_PHONE, DeviceType.fromWire("plan9"))
    }
}
