package dev.vmd1.gossip.features.remote

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Whether another device is currently doing something to this one that the owner should be able to
 * see: its screen being viewed, or its cursor being on this device. `SyncForegroundService` turns this
 * into a persistent notification, so remote access is never silent.
 */
object RemoteActivity {
    private val _remoteInput = MutableStateFlow(false)

    /** True while a Mac's cursor/keyboard is on this device (Universal Control `enter` … `leave`). */
    val remoteInput: StateFlow<Boolean> = _remoteInput

    fun setRemoteInput(active: Boolean) { _remoteInput.value = active }
}
