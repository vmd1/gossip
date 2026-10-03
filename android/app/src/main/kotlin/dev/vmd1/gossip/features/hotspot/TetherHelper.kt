package dev.vmd1.gossip.features.hotspot

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.provider.Settings
import dev.vmd1.gossip.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Turns this phone's Wi-Fi hotspot on/off, trying [MECHANISMS] in order until one reports
 * success. There are currently two ([WriteSecureSettingsMechanism], [ShizukuHotspotMechanism])
 * because Android 16 tightened what used to work — see each mechanism's own doc comment for
 * the version-specific detail. [HotspotToggleMechanism] is the extension point: adding a third
 * mechanism for some future OS lockdown means writing one new object and adding it to
 * [MECHANISMS], not touching this dispatch logic.
 *
 * Which mechanism actually works is genuinely mixed across OEMs/versions in practice (evidence
 * gathered this session shows `TETHER_PRIVILEGED` enforced pre-16 on some devices too) — rather
 * than guess from SDK level alone, callers with an onboarding flow should use
 * [probeMechanisms] once, persist the result locally (a per-device preference, never sent over
 * the wire — see `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2), and pass the winning mechanism's
 * [HotspotToggleMechanism.id] back in to skip straight to it. Absent a persisted preference,
 * [setHotspotEnabled] just tries [MECHANISMS] in order every time, which is the same behavior
 * the old version-gated code had.
 */
object TetherHelper {
    private const val TAG = "TetherHelper"

    private const val WIFI_AP_STATE_DISABLING = 10
    private const val WIFI_AP_STATE_DISABLED = 11
    private const val WIFI_AP_STATE_ENABLING = 12
    private const val WIFI_AP_STATE_ENABLED = 13
    private const val WIFI_AP_STATE_FAILED = 14

    /** Tried in order — cheapest/most-common-case first. [ShizukuHotspotMechanism] is the
     *  fallback for anything [WriteSecureSettingsMechanism] can't handle (Android 16+, or any
     *  OEM/version that enforces `TETHER_PRIVILEGED` earlier than expected). */
    val MECHANISMS: List<HotspotToggleMechanism> = listOf(WriteSecureSettingsMechanism, ShizukuHotspotMechanism)

    enum class ToggleResult { SUCCESS, FAILURE, PERMISSION_DENIED, SHIZUKU_NOT_READY }

    fun isHotspotCapable(context: Context, shizukuManager: ShizukuManager? = null): Boolean =
        hasWriteSettingsPermission(context) || shizukuManager?.state?.value == ShizukuManager.State.CONNECTED

    /** The real gate `TetheringManager.startTethering`'s entitlement-exemption path checks
     *  — confirmed by reading SimpleWear's actual source after `WRITE_SECURE_SETTINGS` alone
     *  (this project's original, wrong assumption) failed live with error 14. Granted either
     *  via `Settings.ACTION_MANAGE_WRITE_SETTINGS` (normal special-access screen, the same
     *  category as "Display over other apps") or `adb shell appops set <pkg>
     *  android:write_settings allow` once declared in the manifest. */
    private fun hasWriteSettingsPermission(context: Context): Boolean = Settings.System.canWrite(context)

    fun requestWriteSettingsIntent(context: Context): android.content.Intent =
        android.content.Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
            .setData(android.net.Uri.parse("package:${context.packageName}"))

    fun isHotspotEnabled(context: Context): Boolean {
        val state = getWifiApState(context)
        return state == WIFI_AP_STATE_ENABLED || state == WIFI_AP_STATE_ENABLING
    }

    /** Polls [isHotspotEnabled] briefly (a real state transition — especially tearing
     *  down — isn't necessarily instantaneous the moment a toggle call returns) rather
     *  than checking once immediately, since a single too-early check could itself
     *  produce a false negative on an otherwise-genuine success. Bounded to ~2s total,
     *  generous relative to how quickly `WIFI_AP_STATE` actually settles in practice
     *  (confirmed live: a real teardown reflects within one or two 400ms polls). */
    private suspend fun verifyState(context: Context, expectedEnabled: Boolean): Boolean {
        repeat(5) {
            if (isHotspotEnabled(context) == expectedEnabled) return true
            delay(400)
        }
        return isHotspotEnabled(context) == expectedEnabled
    }

    private fun getWifiApState(context: Context): Int = runCatching {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_WIFI_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return WIFI_AP_STATE_FAILED
        }
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val method = wifiManager.javaClass.getMethod("getWifiApState")
        method.invoke(wifiManager) as Int
    }.onFailure { Log.w(TAG, "Error getting Wi-Fi AP state", it) }.getOrDefault(WIFI_AP_STATE_FAILED)

    /** Probes each mechanism in [MECHANISMS] for [HotspotToggleMechanism.isAvailable] without
     *  actually toggling anything — cheap enough to call repeatedly (e.g. to refresh an
     *  onboarding permissions screen as the user grants things), unlike [setHotspotEnabled]
     *  which has real side effects. Does not guarantee a mechanism reporting available will
     *  also report success on [HotspotToggleMechanism.trySetEnabled]; onboarding's one-time
     *  "test hotspot methods" step should actually attempt the toggle (see
     *  `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2) rather than relying on this alone. */
    suspend fun probeMechanisms(context: Context, shizukuManager: ShizukuManager? = null): List<HotspotToggleMechanism> =
        MECHANISMS.filter { it.isAvailable(context, shizukuManager) }

    /** Suspends until the toggle attempt finishes (or [timeoutMs] elapses). Must be called
     *  from a coroutine — the underlying platform APIs are callback-based.
     *
     *  [shizukuManager] is optional — pass it whenever it's available (it's how the caller
     *  opts into [ShizukuHotspotMechanism]).
     *
     *  [preferredMechanismId] lets a caller that already knows which mechanism works on this
     *  device (from onboarding's persisted probe result) skip straight to it instead of
     *  retrying [MECHANISMS] in order; unset or unrecognized falls back to the full ordered
     *  list, same as before onboarding existed. */
    suspend fun setHotspotEnabled(
        context: Context,
        enable: Boolean,
        shizukuManager: ShizukuManager? = null,
        timeoutMs: Long = 10_000,
        preferredMechanismId: String? = null
    ): ToggleResult {
        val ordered = orderedMechanisms(MECHANISMS, preferredMechanismId)

        var sawShizukuNotReady = false
        for (mechanism in ordered) {
            if (!mechanism.isAvailable(context, shizukuManager)) {
                if (mechanism is ShizukuHotspotMechanism) sawShizukuNotReady = true
                Log.w(TAG, "${mechanism.id} not available; trying next mechanism if any")
                continue
            }
            val result = withTimeoutOrNull(timeoutMs) { mechanism.trySetEnabled(context, shizukuManager, enable) }
            if (result == true) {
                // A mechanism reporting success isn't itself trustworthy — confirmed
                // live: `ShizukuHotspotMechanism`'s stop path returned
                // `TETHER_ERROR_NO_ERROR` twice in a row while `dumpsys wifi` showed
                // the exact same `SoftApManager` instance still alive the whole time
                // (a hidden-AIDL overload/attribution-tag mismatch on that specific
                // device build — see that mechanism's doc comment). Poll the real
                // `WIFI_AP_STATE` briefly rather than trusting the callback alone;
                // a mechanism that can't actually be verified is treated as failed so
                // the next mechanism in [ordered] gets a real chance, instead of
                // silently reporting a toggle that didn't happen.
                if (verifyState(context, expectedEnabled = enable)) return ToggleResult.SUCCESS
                Log.w(TAG, "${mechanism.id} reported success but real hotspot state didn't confirm it; trying next mechanism if any")
                continue
            }
            Log.w(TAG, "${mechanism.id} failed or timed out; trying next mechanism if any")
        }
        return if (sawShizukuNotReady) ToggleResult.SHIZUKU_NOT_READY else ToggleResult.FAILURE
    }

    /** Pure ordering logic, factored out of [setHotspotEnabled] so it's testable on the
     *  plain JVM without a [Context] or real mechanism implementations (both of which
     *  [HotspotToggleMechanism.isAvailable]/`trySetEnabled` need) — see
     *  `OrderedMechanismsTest`. [preferredMechanismId] moves that mechanism (if found in
     *  [mechanisms]) to the front, preserving the relative order of the rest; unset or
     *  unrecognized returns [mechanisms] unchanged. */
    internal fun orderedMechanisms(
        mechanisms: List<HotspotToggleMechanism>,
        preferredMechanismId: String?
    ): List<HotspotToggleMechanism> =
        preferredMechanismId
            ?.let { id -> mechanisms.find { it.id == id } }
            ?.let { preferred -> listOf(preferred) + (mechanisms - preferred) }
            ?: mechanisms
}
