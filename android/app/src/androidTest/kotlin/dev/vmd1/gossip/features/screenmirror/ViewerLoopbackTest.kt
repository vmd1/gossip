package dev.vmd1.gossip.features.screenmirror

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Runs the real viewer transport ([WebSocketClient] + viewer-side [ScreenCipher]) against the real source-side
 * [WebSocketConnection] + device-side [ScreenCipher], on a real device, with the bridge's framing: sealed hello,
 * sealed text header, sealed binary video/size messages, sealed control message back. No Shizuku needed.
 */
@RunWith(AndroidJUnit4::class)
class ViewerLoopbackTest {
    private val kindText: Byte = 0
    private val kindBinary: Byte = 1

    @Test
    fun viewerAndBridgeTransportInteroperate() {
        val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val sessionId = "loopback-session"
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val controlReceived = CountDownLatch(1)
        var receivedControl: ByteArray? = null
        var helloOk = false

        val bridge = thread {
            val ws = WebSocketConnection.accept(server.accept())
            val cipher = ScreenCipher(secret, sessionId, deviceSide = true)
            val hello = cipher.open(ws.readMessage()!!.data)
            helloOk = hello[0] == kindBinary && String(hello.copyOfRange(1, hello.size)) == sessionId
            ws.sendBinary(cipher.seal(byteArrayOf(kindText) + """{"codec":"h264","width":1080,"height":2400,"deviceName":"Test","audio":null}""".toByteArray()))
            val video = ByteBuffer.allocate(1 + 8 + 3).put(0).putLong(BridgeMessage.CONFIG_FLAG).put(byteArrayOf(0, 0, 1)).array()
            ws.sendBinary(cipher.seal(byteArrayOf(kindBinary) + video))
            ws.sendBinary(cipher.seal(byteArrayOf(kindBinary) + byteArrayOf(1) + ByteBuffer.allocate(8).putInt(720).putInt(1280).array()))
            val control = cipher.open(ws.readMessage()!!.data)
            receivedControl = control.copyOfRange(1, control.size)
            controlReceived.countDown()
            ws.close()
        }

        val client = WebSocketClient.connect(InetAddress.getByName("127.0.0.1"), server.localPort, "/screen")
        val cipher = ScreenCipher(secret, sessionId, deviceSide = false)
        client.sendBinary(cipher.seal(byteArrayOf(kindBinary) + sessionId.toByteArray()))

        val header = cipher.open(client.readMessage()!!.data)
        assertEquals(kindText, header[0])
        val parsed = BridgeStreamHeader.parse(String(header.copyOfRange(1, header.size)))!!
        assertEquals(1080, parsed.width); assertEquals("Test", parsed.deviceName)

        val v = cipher.open(client.readMessage()!!.data)
        val video = BridgeMessage.parse(v.copyOfRange(1, v.size)) as BridgeMessage.Video
        assertTrue(video.isConfig)
        val s = cipher.open(client.readMessage()!!.data)
        assertEquals(BridgeMessage.Size(720, 1280), BridgeMessage.parse(s.copyOfRange(1, s.size)))

        client.sendBinary(cipher.seal(byteArrayOf(kindBinary) + ScrcpyControl.RESET_VIDEO))
        assertTrue(controlReceived.await(5, TimeUnit.SECONDS))
        assertTrue(helloOk)
        assertArrayEquals(ScrcpyControl.RESET_VIDEO, receivedControl)
        bridge.join(2000)
        client.close(); server.close()
    }
}
