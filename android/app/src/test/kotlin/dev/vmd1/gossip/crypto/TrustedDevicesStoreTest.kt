package dev.vmd1.gossip.crypto

import dev.vmd1.gossip.protocol.DeviceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TrustedDevicesStoreTest {

    private lateinit var store: TrustedDevicesStore

    @Before
    fun setUp() {
        store = TrustedDevicesStore(FakeSharedPreferences())
    }

    @Test
    fun `a device is untrusted until added, then trusted, then forgotten`() {
        val deviceId = "11111111-1111-1111-1111-111111111111"
        assertFalse(store.isTrusted(deviceId))

        store.addDevice(
            TrustedDevice(
                deviceId = deviceId,
                publicKey = byteArrayOf(1, 2, 3, 4),
                deviceName = "Vivaan's MacBook",
                deviceType = DeviceType.MAC,
                addedAt = 1_700_000_000_000L
            )
        )

        assertTrue(store.isTrusted(deviceId))
        val loaded = store.getDevice(deviceId)
        assertEquals("Vivaan's MacBook", loaded?.deviceName)
        assertEquals(DeviceType.MAC, loaded?.deviceType)
        assertTrue(loaded!!.publicKey.contentEquals(byteArrayOf(1, 2, 3, 4)))

        store.revoke(deviceId)
        assertFalse(store.isTrusted(deviceId))
        assertNull(store.getDevice(deviceId))
    }

    @Test
    fun `survives a simulated app restart by rewrapping the same backing preferences`() {
        val prefs = FakeSharedPreferences()
        val first = TrustedDevicesStore(prefs)
        first.addDevice(
            TrustedDevice(
                deviceId = "device-a",
                publicKey = byteArrayOf(9, 9, 9),
                deviceName = "Phone A",
                deviceType = DeviceType.ANDROID_PHONE,
                addedAt = 42L
            )
        )

        // Simulate the process dying and the store being rebuilt from the same
        // (encrypted, on-disk in production) SharedPreferences.
        val second = TrustedDevicesStore(prefs)
        assertTrue(second.isTrusted("device-a"))
        assertEquals(1, second.allDevices().size)
    }

    @Test
    fun `allDevices lists multiple trusted devices, supporting the multi-device ecosystem goal`() {
        store.addDevice(TrustedDevice("mac-1", byteArrayOf(1), "Mac", DeviceType.MAC, 1L))
        store.addDevice(TrustedDevice("tablet-1", byteArrayOf(2), "Tablet", DeviceType.ANDROID_TABLET, 2L))

        val all = store.allDevices()
        assertEquals(2, all.size)
        assertTrue(all.any { it.deviceId == "mac-1" })
        assertTrue(all.any { it.deviceId == "tablet-1" })
    }

    @Test
    fun `a row written by an older build with a since-removed field still loads`() {
        val prefs = FakeSharedPreferences()
        val legacy = """{"deviceId":"22222222-2222-2222-2222-222222222222","publicKeyBase64":"AQIDBA==",""" +
            """"deviceName":"Old phone","deviceType":"android-phone","addedAt":1700000000000,""" +
            """"lockOnLeaveEnabled":true,"autoHotspotRequestEligible":true}"""
        prefs.edit().putString("device_22222222-2222-2222-2222-222222222222", legacy).apply()

        val loaded = TrustedDevicesStore(prefs).getDevice("22222222-2222-2222-2222-222222222222")

        assertEquals("Old phone", loaded?.deviceName)
        assertTrue(loaded!!.lockOnLeaveEnabled)
    }
}
