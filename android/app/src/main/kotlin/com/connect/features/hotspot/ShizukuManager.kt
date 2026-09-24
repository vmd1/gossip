package com.connect.features.hotspot

import android.content.Context
import android.content.pm.PackageManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuProvider

/**
 * Tracks Shizuku's lifecycle (installed / running / permission granted) — the only piece
 * of Instant Hotspot that needs Shizuku at all: on Android 16+, `TetheringManager.
 * startTethering` requires the signature-only `TETHER_PRIVILEGED` permission, which
 * neither `WRITE_SECURE_SETTINGS` nor plain shell grants satisfy (confirmed exhaustively —
 * see `TetherHelper.kt`'s doc comment and `docs/ble-hotspot-protocol.md`). Shizuku gives
 * this app a shell-UID Binder handle, and calling the raw hidden tethering AIDL interface
 * with the caller package spoofed as `"com.android.shell"` satisfies whatever check
 * rejects a normal app's own identity — the same technique the real, currently-maintained
 * Delta (`github.com/supershadoe/delta`) and SimpleWear's `wearsettings` companion app
 * both use. **Only needed on Android 16+**: `TetherHelper.setHotspotEnabled` falls back to
 * the plain `WRITE_SECURE_SETTINGS` + reflection path (no Shizuku, no onboarding) on
 * Android 10–15, where that path alone is still sufficient.
 */
class ShizukuManager(context: Context) {
    enum class State {
        /** Shizuku isn't installed on this device (and Sui/root isn't active either). */
        NOT_AVAILABLE,
        /** Installed, but its privileged server isn't currently running. */
        NOT_RUNNING,
        /** Server is up, but this app hasn't been granted permission yet. */
        NOT_CONNECTED,
        /** Server is up and this app is granted — ready to make privileged calls. */
        CONNECTED
    }

    private val appContext = context.applicationContext
    private val _state = MutableStateFlow(determineInitialState())
    val state: StateFlow<State> = _state.asStateFlow()

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { _, grantResult ->
        _state.value = stateWhenAlive(grantResult)
    }

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        _state.value = stateWhenAlive(Shizuku.checkSelfPermission())
    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {
        _state.value = stateWhenDead()
    }

    /** Call once (e.g. from `SyncForegroundService.onCreate`) to start reacting to Shizuku's
     *  binder lifecycle. There is no matching `stop()` — these listeners are meant to live
     *  for the process's lifetime, same as `Shizuku`'s own static registration API. */
    fun start() {
        Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
        Shizuku.addBinderDeadListener(binderDeadListener)
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    /** Triggers the one-time system permission dialog. Only meaningful in
     *  [State.NOT_CONNECTED] (binder alive, not yet granted) — a no-op otherwise. Requires
     *  the phone to be unlocked with the UI visible, same category as the device-admin /
     *  Bluetooth onboarding prompts elsewhere in this app; the grant then persists across
     *  reboots (until the user revokes it in Shizuku's own app or it's uninstalled). */
    fun requestPermission() {
        if (_state.value == State.NOT_CONNECTED) {
            Shizuku.requestPermission(PERMISSION_REQUEST_CODE)
        }
    }

    private fun isShizukuInstalled(): Boolean =
        runCatching { appContext.packageManager.getApplicationInfo(ShizukuProvider.MANAGER_APPLICATION_ID, 0) }
            .isSuccess

    private fun stateWhenAlive(permissionResult: Int): State =
        if (permissionResult == PackageManager.PERMISSION_GRANTED) State.CONNECTED else State.NOT_CONNECTED

    private fun stateWhenDead(): State = if (isShizukuInstalled()) State.NOT_RUNNING else State.NOT_AVAILABLE

    private fun determineInitialState(): State = when {
        Shizuku.pingBinder() -> stateWhenAlive(Shizuku.checkSelfPermission())
        else -> stateWhenDead()
    }

    companion object {
        private const val PERMISSION_REQUEST_CODE = 24601
    }
}
