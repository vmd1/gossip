package com.connect.features.screenmirror

import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.MessageRouter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The Android side of the screen-mirroring signaling protocol (`screen.start`
 * / `screen.stop`, see `schema/message-types.md`).
 *
 * This is deliberately a thin, UI-only shim: the actual mirroring pipeline
 * (H.264 capture + streaming) runs entirely on the Mac, driven directly over
 * an `adb`-forwarded tunnel — see `mac/Connect/Features/ScreenMirror/`. The
 * phone has nothing to *do* when it receives `screen.start`/`screen.stop`
 * over the Noise-encrypted transport; this object exists purely so a future
 * "Mirroring active" indicator in the Android UI has something to observe.
 * Registering a handler here does not make mirroring depend on the
 * transport being connected in any way.
 */
class ScreenMirrorState {
    private val _isMirroring = MutableStateFlow(false)
    val isMirroring: StateFlow<Boolean> = _isMirroring

    /** Registers this instance's handlers with [router] for the `screen.` namespace. */
    fun register(router: MessageRouter) {
        router.register(MessageType.SCREEN_START, EnvelopeHandler { onScreenStart(it) })
        router.register(MessageType.SCREEN_STOP, EnvelopeHandler { onScreenStop(it) })
    }

    private fun onScreenStart(@Suppress("UNUSED_PARAMETER") envelope: Envelope) {
        _isMirroring.value = true
    }

    private fun onScreenStop(@Suppress("UNUSED_PARAMETER") envelope: Envelope) {
        _isMirroring.value = false
    }
}
