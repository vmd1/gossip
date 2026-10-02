package dev.vmd1.gossip.features.universalcontrol

import java.io.ByteArrayOutputStream

/**
 * HID report descriptors and report encoders for the two virtual devices created through scrcpy's UHID
 * control messages, plus the scrcpy control-message framing for them. Pure functions, unit-tested.
 *
 * scrcpy control messages (big-endian): `UHID_CREATE` = 12 `[u16 id][u16 vendor][u16 product][u8 nameLen][name]
 * [u16 descLen][desc]`, `UHID_INPUT` = 13 `[u16 id][u16 len][report]`, `UHID_DESTROY` = 14 `[u16 id]`,
 * `INJECT_TEXT` = 1 `[u32 len][utf8]`, `SET_CLIPBOARD` = 9 `[u64 sequence][u8 paste][u32 len][utf8]`.
 */
object HidReports {
    const val MOUSE_ID = 0x4701
    const val KEYBOARD_ID = 0x4702

    const val CONTROL_INJECT_TEXT = 1
    const val CONTROL_SET_CLIPBOARD = 9
    const val CONTROL_UHID_CREATE = 12
    const val CONTROL_UHID_INPUT = 13
    const val CONTROL_UHID_DESTROY = 14

    /** Buttons(5) + padding(3), 16-bit relative X/Y, 8-bit wheel, 8-bit horizontal wheel (AC Pan). 7-byte reports. */
    val MOUSE_DESCRIPTOR: ByteArray = intArrayOf(
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x06,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    ).toBytes()

    /** Standard boot-protocol keyboard: modifier byte, reserved, six key slots. 8-byte reports. */
    val KEYBOARD_DESCRIPTOR: ByteArray = intArrayOf(
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
    ).toBytes()

    private fun IntArray.toBytes() = ByteArray(size) { this[it].toByte() }

    /** One mouse report. [dx]/[dy] are clamped to the descriptor's -32767..32767, [wheel]/[pan] to -127..127. */
    fun mouseReport(buttons: Int, dx: Int, dy: Int, wheel: Int = 0, pan: Int = 0): ByteArray {
        val x = dx.coerceIn(-32767, 32767); val y = dy.coerceIn(-32767, 32767)
        return byteArrayOf(
            (buttons and 0x1f).toByte(),
            (x and 0xff).toByte(), ((x shr 8) and 0xff).toByte(),
            (y and 0xff).toByte(), ((y shr 8) and 0xff).toByte(),
            wheel.coerceIn(-127, 127).toByte(), pan.coerceIn(-127, 127).toByte(),
        )
    }

    /** Boot keyboard report from [modifiers] and up to six pressed [usages] (extra ones are dropped: rollover). */
    fun keyboardReport(modifiers: Int, usages: Collection<Int>): ByteArray {
        val r = ByteArray(8)
        r[0] = modifiers.toByte()
        usages.filter { it in 4..0x65 }.take(6).forEachIndexed { i, u -> r[2 + i] = u.toByte() }
        return r
    }

    private fun msg(block: ByteArrayOutputStream.() -> Unit) = ByteArrayOutputStream().apply(block).toByteArray()
    private fun ByteArrayOutputStream.u8(v: Int) = write(v and 0xff)
    private fun ByteArrayOutputStream.u16(v: Int) { u8(v shr 8); u8(v) }
    private fun ByteArrayOutputStream.u32(v: Int) { u16(v ushr 16); u16(v) }

    fun create(id: Int, name: String, descriptor: ByteArray, vendor: Int = 0x18d1, product: Int = 0x4e00): ByteArray = msg {
        val n = name.toByteArray(Charsets.UTF_8)
        u8(CONTROL_UHID_CREATE); u16(id); u16(vendor); u16(product + (id and 0xff)); u8(n.size); write(n)
        u16(descriptor.size); write(descriptor)
    }

    fun input(id: Int, report: ByteArray): ByteArray = msg { u8(CONTROL_UHID_INPUT); u16(id); u16(report.size); write(report) }
    fun destroy(id: Int): ByteArray = msg { u8(CONTROL_UHID_DESTROY); u16(id) }
    fun injectText(text: String): ByteArray = msg {
        val t = text.toByteArray(Charsets.UTF_8); u8(CONTROL_INJECT_TEXT); u32(t.size); write(t)
    }
    /** Sets the device clipboard to [text] and pastes it (Ctrl+V) — the path for text `INJECT_TEXT` can't type. */
    fun pasteText(text: String): ByteArray = msg {
        val t = text.toByteArray(Charsets.UTF_8)
        u8(CONTROL_SET_CLIPBOARD); u16(0); u16(0); u16(0); u16(0) // u64 sequence = 0 (no ack wanted)
        u8(1); u32(t.size); write(t)
    }
}
