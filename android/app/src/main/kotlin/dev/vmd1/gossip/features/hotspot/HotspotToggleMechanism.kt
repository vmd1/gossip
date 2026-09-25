package dev.vmd1.gossip.features.hotspot

import android.content.Context
import android.net.ConnectivityManager
import android.net.IIntResultListener
import android.net.ITetheringConnector
import android.net.TetheringManagerHidden
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper
import java.lang.reflect.Proxy
import java.util.concurrent.Executor
import kotlin.coroutines.resume

/**
 * One way of flipping the phone's Wi-Fi hotspot on/off. [TetherHelper] tries an ordered list
 * of these rather than branching inline on OS version — this is the generalization the old
 * `TODO(onboarding)` comment on `setHotspotEnabled` was gesturing at: a device's onboarding
 * flow can probe [isAvailable]/attempt [trySetEnabled] on each mechanism once, remember which
 * one actually worked, and skip straight to it at runtime instead of re-guessing from SDK level.
 *
 * Adding a third mechanism (e.g. a hypothetical future OS locking this down differently) means
 * writing one new object and adding it to [TetherHelper.MECHANISMS] — no changes to the calling
 * code or to the other mechanisms.
 */
interface HotspotToggleMechanism {
    /** Short, stable identifier — used as the onboarding persisted-preference key, so treat
     *  it like part of the mechanism's public contract; don't rename casually. */
    val id: String

    /** Cheap, side-effect-free check for whether this mechanism is worth attempting right now
     *  (permission already granted / Shizuku already connected, etc). Does not itself prove
     *  the mechanism will *work* on this device/OS build — only that trying it isn't pointless. */
    suspend fun isAvailable(context: Context, shizukuManager: ShizukuManager?): Boolean

    /** Attempts the toggle. Returns true on confirmed success. Callers are expected to
     *  enforce their own timeout budget around this call if needed. */
    suspend fun trySetEnabled(context: Context, shizukuManager: ShizukuManager?, enable: Boolean): Boolean
}

/**
 * **Android 10–15 (and a best-effort attempt on any version)**: reflection against
 * `ConnectivityManager`/`TetheringManager.startTethering`/`stopTethering`, gated on the
 * `WRITE_SECURE_SETTINGS`/`Settings.System.canWrite` permission — the same hidden framework
 * path real third-party "toggle my phone's hotspot" apps use (verified directly against
 * SimpleWear's open-source `TetherHelper.kt`, not guessed). Confirmed dead on Android 16 (see
 * [ShizukuHotspotMechanism]'s doc) but left generally-available rather than version-gated here,
 * since evidence this session showed the cutoff isn't uniformly exactly API 36 across OEMs —
 * [TetherHelper] orders mechanisms so the cheap one is tried first and the fallback covers the
 * rest.
 */
object WriteSecureSettingsMechanism : HotspotToggleMechanism {
    override val id = "write_secure_settings"

    private const val TAG = "TetherHelper"
    private const val TETHERING_WIFI = 0
    private const val TETHERING_SERVICE = "tethering"
    private const val TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION = 14

    override suspend fun isAvailable(context: Context, shizukuManager: ShizukuManager?): Boolean =
        Settings.System.canWrite(context)

    override suspend fun trySetEnabled(context: Context, shizukuManager: ShizukuManager?, enable: Boolean): Boolean {
        if (!Settings.System.canWrite(context)) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (enable) startTethering(context) else stopTethering(context)
        } else {
            startOrStopTetheringPreR(context, enable)
        }
    }

    @Suppress("DEPRECATION")
    private fun startOrStopTetheringPreR(context: Context, enable: Boolean): Boolean = runCatching {
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (!enable) {
            val method = cm.javaClass.getMethod("stopTethering", Int::class.java)
            method.invoke(cm, TETHERING_WIFI)
            return true
        }
        true.also {
            val callbackClass = Class.forName("android.net.ConnectivityManager\$OnStartTetheringCallback")
            val method = cm.javaClass.getMethod(
                "startTethering",
                Int::class.java,
                Boolean::class.java,
                callbackClass,
                Handler::class.java
            )
            val proxy = Proxy.newProxyInstance(callbackClass.classLoader, arrayOf(callbackClass)) { _, _, _ -> null }
            method.invoke(cm, TETHERING_WIFI, false, proxy, Handler(Looper.getMainLooper()))
        }
    }.onFailure { Log.w(TAG, "startOrStopTetheringPreR failed", it) }.getOrDefault(false)

    private suspend fun startTethering(context: Context, allowRetry: Boolean = true): Boolean =
        suspendCancellableCoroutine { continuation ->
            runCatching {
                val tetheringManager = context.applicationContext.getSystemService(TETHERING_SERVICE)
                val tetheringManagerClass = Class.forName("android.net.TetheringManager")
                val requestClass = Class.forName("android.net.TetheringManager\$TetheringRequest")
                val requestBuilderClass = Class.forName("android.net.TetheringManager\$TetheringRequest\$Builder")
                val callbackClass = Class.forName("android.net.TetheringManager\$StartTetheringCallback")

                // First attempt exempts the entitlement check (the common case for a normal
                // carrier plan); if that's specifically what's rejected (error 14), SimpleWear's
                // reference implementation retries once without the exemption rather than
                // giving up — mirrored here.
                val request = requestBuilderClass.getConstructor(Int::class.java)
                    .newInstance(TETHERING_WIFI)
                    .let { builder ->
                        requestBuilderClass.getMethod("setExemptFromEntitlementCheck", Boolean::class.java)
                            .invoke(builder, allowRetry)
                        requestBuilderClass.getMethod("setShouldShowEntitlementUi", Boolean::class.java)
                            .invoke(builder, false)
                        requestBuilderClass.getMethod("build").invoke(builder)
                    }

                val proxy = Proxy.newProxyInstance(callbackClass.classLoader, arrayOf(callbackClass)) { _, method, args ->
                    when (method?.name) {
                        "onTetheringStarted" -> if (continuation.isActive) continuation.resume(true)
                        "onTetheringFailed" -> {
                            val code = (args?.getOrNull(0) as? Int) ?: -1
                            Log.w(
                                TAG,
                                "onTetheringFailed: code=$code" +
                                    if (code == TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION) " (entitlement check rejected; will retry without exemption)" else ""
                            )
                            if (continuation.isActive) continuation.resume(false)
                        }
                    }
                    null
                }

                val startMethod = tetheringManagerClass.getMethod(
                    "startTethering", requestClass, Executor::class.java, callbackClass
                )
                startMethod.invoke(tetheringManager, request, Executor { it.run() }, proxy)
            }.onFailure {
                Log.w(TAG, "startTethering failed", it)
                if (continuation.isActive) continuation.resume(false)
            }
        }.let { result ->
            if (!result && allowRetry) startTethering(context, allowRetry = false) else result
        }

    private fun stopTethering(context: Context): Boolean = runCatching {
        val tetheringManager = context.applicationContext.getSystemService(TETHERING_SERVICE)
        val tetheringManagerClass = Class.forName("android.net.TetheringManager")
        val method = tetheringManagerClass.getMethod("stopTethering", Int::class.java)
        method.invoke(tetheringManager, TETHERING_WIFI)
        true
    }.onFailure { Log.w(TAG, "stopTethering failed", it) }.getOrDefault(false)
}

/**
 * **Required on Android 16+, usable as a fallback on any version**: `WRITE_SECURE_SETTINGS`
 * alone is confirmed insufficient on Android 16 (verified exhaustively on real Samsung/API 36
 * hardware — both `TetheringManager.startTethering` attempts, entitlement-exempt and the
 * SimpleWear-style retry without it, fail with error 14/`TETHER_ERROR_NO_CHANGE_TETHERING_
 * PERMISSION`; even `adb shell cmd wifi start-softap` itself is denied with a
 * `SecurityException`). Android 16 requires the signature-only `TETHER_PRIVILEGED` permission,
 * which nothing short of Shizuku or root grants a normal app. This uses [ShizukuManager] to get
 * a shell-UID Binder handle, then calls the raw hidden `ITetheringConnector` AIDL interface
 * directly (not the public `TetheringManager` wrapper, which ties the call to this app's own
 * real identity/UID and is exactly what gets rejected) with the caller package spoofed as
 * `"com.android.shell"` — confirmed via a real, currently-maintained reference app
 * (`github.com/supershadoe/delta`) and mirrored by SimpleWear's own `wearsettings` companion
 * app. See `docs/ble-hotspot-protocol.md`'s "Open blocker" section for the full research trail.
 */
object ShizukuHotspotMechanism : HotspotToggleMechanism {
    override val id = "shizuku_raw_aidl"

    private const val TAG = "TetherHelper"
    private const val TETHERING_WIFI = 0
    private const val TETHERING_SERVICE = "tethering"
    private const val TETHER_ERROR_NO_ERROR = 0

    /** Caller package spoofed on every Shizuku/raw-AIDL tethering call — matches Delta's and
     *  SimpleWear's own constant. Running as shell UID *and* asserting this identity together
     *  are what satisfy the check that rejects this app's own real identity. */
    private const val ADB_PACKAGE_NAME = "com.android.shell"

    override suspend fun isAvailable(context: Context, shizukuManager: ShizukuManager?): Boolean =
        shizukuManager?.state?.value == ShizukuManager.State.CONNECTED

    override suspend fun trySetEnabled(context: Context, shizukuManager: ShizukuManager?, enable: Boolean): Boolean {
        if (shizukuManager == null || shizukuManager.state.value != ShizukuManager.State.CONNECTED) {
            Log.w(TAG, "Shizuku not connected; cannot toggle hotspot")
            return false
        }
        return suspendCancellableCoroutine { continuation ->
            runCatching {
                val binder = SystemServiceHelper.getSystemService(TETHERING_SERVICE)
                    ?: error("Unable to get system service: $TETHERING_SERVICE")
                val tetheringConnector = ITetheringConnector.Stub.asInterface(ShizukuBinderWrapper(binder))
                val listener = object : IIntResultListener.Stub() {
                    override fun onResult(resultCode: Int) {
                        Log.i(TAG, "Shizuku tethering result: $resultCode")
                        if (continuation.isActive) continuation.resume(resultCode == TETHER_ERROR_NO_ERROR)
                    }
                }
                if (enable) {
                    val request = TetheringManagerHidden.TetheringRequest.Builder(TETHERING_WIFI)
                        .setExemptFromEntitlementCheck(true)
                        .setShouldShowEntitlementUi(false)
                        .build()
                    startTetheringWithFallback(tetheringConnector, request, listener)
                } else {
                    stopTetheringWithFallback(tetheringConnector, listener)
                }
            }.onFailure {
                Log.w(TAG, "Shizuku tethering call failed", it)
                if (continuation.isActive) continuation.resume(false)
            }
        }
    }

    /** Tries each `startTethering` overload our vendored `ITetheringConnector` stub
     *  declares, oldest-signature-last, falling through on `NoSuchMethodException` —
     *  same call shapes, same order, same `null` (not `""`) attribution tag as the
     *  real, currently-maintained reference this technique is based on
     *  (`github.com/supershadoe/delta`'s `SoftApController.startSoftAp`), since a live
     *  device's actual platform build may only implement one specific overload of this
     *  hidden AIDL method — calling the wrong one throws `NoSuchMethodException`
     *  (the `dev.rikka.tools.refine` bytecode-rewriting this whole mechanism depends on
     *  swaps this stub's calls for the real on-device `ITetheringConnector` class at
     *  runtime; if that real class doesn't have a matching overload, the call fails
     *  this way rather than silently). Unlike the stop path below, every overload here
     *  still accepts our own [IIntResultListener], so the real result is always
     *  reported back through [listener] regardless of which overload actually worked. */
    private fun startTetheringWithFallback(
        tetheringConnector: ITetheringConnector,
        request: TetheringManagerHidden.TetheringRequest,
        listener: IIntResultListener
    ) {
        try {
            tetheringConnector.startTethering(request.parcel, ADB_PACKAGE_NAME, null, listener)
        } catch (_: NoSuchMethodException) {
            try {
                tetheringConnector.startTethering(request.parcel, ADB_PACKAGE_NAME, listener)
            } catch (_: NoSuchMethodException) {
                // The two oldest overloads take a `ResultReceiver`, not an
                // `IIntResultListener` — different callback ABI entirely, from before
                // this AIDL interface had the newer listener-based shape. Bridge it
                // back to our own listener so the caller still gets a real result.
                val resultReceiver = object : android.os.ResultReceiver(Handler(Looper.getMainLooper())) {
                    override fun onReceiveResult(resultCode: Int, resultData: android.os.Bundle?) {
                        listener.onResult(resultCode)
                    }
                }
                try {
                    tetheringConnector.startTethering(TETHERING_WIFI, resultReceiver, false, ADB_PACKAGE_NAME)
                } catch (_: NoSuchMethodException) {
                    tetheringConnector.startTethering(TETHERING_WIFI, resultReceiver, false)
                }
            }
        }
    }

    /** Same fallback strategy as [startTetheringWithFallback], for `stopTethering` —
     *  see that method's doc comment. This is the path that was live-confirmed
     *  *not* actually stopping the AP despite reporting `TETHER_ERROR_NO_ERROR` when
     *  called with the newer 4-arg overload and an empty-string (not `null`)
     *  attribution tag; switching to `null` and adding the same overload fallback
     *  Delta already ships and has verified across real devices is the fix. */
    private fun stopTetheringWithFallback(tetheringConnector: ITetheringConnector, listener: IIntResultListener) {
        try {
            tetheringConnector.stopTethering(TETHERING_WIFI, ADB_PACKAGE_NAME, null, listener)
        } catch (_: NoSuchMethodException) {
            try {
                tetheringConnector.stopTethering(TETHERING_WIFI, ADB_PACKAGE_NAME, listener)
            } catch (_: NoSuchMethodException) {
                // No callback parameter at all on this oldest overload — report success
                // optimistically (this is Delta's own behavior too: `stopSoftAp`
                // returns `true` immediately after this call with no result
                // confirmation available). `TetherHelper`'s caller-side state
                // verification (see its doc comment) is what actually catches a
                // silent no-op here, not this return value.
                tetheringConnector.stopTethering(TETHERING_WIFI)
                listener.onResult(TETHER_ERROR_NO_ERROR)
            }
        }
    }
}
