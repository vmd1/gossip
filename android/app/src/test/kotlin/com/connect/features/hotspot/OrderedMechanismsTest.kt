package com.connect.features.hotspot

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Test

/** Fake [HotspotToggleMechanism] — [orderedMechanisms] only ever reads [id], so
 *  [isAvailable]/[trySetEnabled] are never actually called by the tests below. */
private class FakeMechanism(override val id: String) : HotspotToggleMechanism {
    override suspend fun isAvailable(context: Context, shizukuManager: ShizukuManager?): Boolean =
        error("not used by orderedMechanisms")

    override suspend fun trySetEnabled(context: Context, shizukuManager: ShizukuManager?, enable: Boolean): Boolean =
        error("not used by orderedMechanisms")
}

class OrderedMechanismsTest {

    private val a = FakeMechanism("a")
    private val b = FakeMechanism("b")
    private val c = FakeMechanism("c")
    private val mechanisms = listOf(a, b, c)

    @Test
    fun `null preference returns the list unchanged`() {
        assertEquals(listOf(a, b, c), TetherHelper.orderedMechanisms(mechanisms, null))
    }

    @Test
    fun `unrecognized preference returns the list unchanged`() {
        assertEquals(listOf(a, b, c), TetherHelper.orderedMechanisms(mechanisms, "does_not_exist"))
    }

    @Test
    fun `preference already at the front is a no-op`() {
        assertEquals(listOf(a, b, c), TetherHelper.orderedMechanisms(mechanisms, "a"))
    }

    @Test
    fun `preference in the middle moves to the front, preserving the rest's order`() {
        assertEquals(listOf(b, a, c), TetherHelper.orderedMechanisms(mechanisms, "b"))
    }

    @Test
    fun `preference at the end moves to the front, preserving the rest's order`() {
        assertEquals(listOf(c, a, b), TetherHelper.orderedMechanisms(mechanisms, "c"))
    }

    @Test
    fun `TetherHelper MECHANISMS puts WriteSecureSettings before Shizuku by default`() {
        // The real (non-fake) default order matters — WriteSecureSettingsMechanism is the
        // cheap, no-extra-app-required path and should always be tried first.
        assertEquals(
            listOf(WriteSecureSettingsMechanism, ShizukuHotspotMechanism),
            TetherHelper.MECHANISMS
        )
    }
}
