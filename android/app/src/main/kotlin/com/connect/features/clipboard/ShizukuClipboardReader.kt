package com.connect.features.clipboard

import android.util.Log
import com.connect.features.hotspot.ShizukuManager
import org.lsposed.hiddenapibypass.HiddenApiBypass
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper

/**
 * Reads the system clipboard's current plain-text value via a Shizuku-brokered shell-UID
 * Binder call to the raw hidden `android.content.IClipboard` interface, instead of the
 * normal `ClipboardManager` — the only way to read the clipboard from the background at
 * all (see [ClipboardSyncManager]'s doc comment for the restriction this works around).
 * Confirmed via a real, currently-maintained reference app doing exactly this for the same
 * purpose (Mac↔Android clipboard sync): `github.com/chakri192/clipsyncd`'s
 * `ShizukuClipboard.kt`. Unlike Instant Hotspot's `ITetheringConnector` path
 * (`features/hotspot/TetherHelper.kt`), this doesn't need the heavier Refine/module-split
 * machinery — `IClipboard` is reflected into fresh on every read rather than statically
 * linked, so it only needs Android's non-SDK-interface reflection restriction lifted (via
 * [HiddenApiBypass]), not a compile-time stub.
 *
 * **Image reads are not implemented here** — only text. `IClipboard.getPrimaryClip`
 * returns a real `ClipData`, whose image items are `content://` Uris backed by the
 * *source* app's own `FileProvider`; resolving that cross-process without that app's
 * explicit grant is its own separate problem this class doesn't attempt to solve. Text
 * covers the overwhelmingly common case and is what actually motivated this (URLs,
 * snippets, codes) — [ClipboardSyncManager] still only picks up a background image copy
 * once the app regains focus, exactly as before.
 *
 * **Read-only**: writing to the clipboard (the receive direction) was never affected by
 * the background restriction and continues to use the normal `ClipboardManager` API — see
 * [ClipboardSyncManager.onRemoteUpdate].
 */
object ShizukuClipboardReader {
    private const val TAG = "ShizukuClipboardReader"
    private const val CALLING_PACKAGE = "com.android.shell"

    init {
        runCatching { HiddenApiBypass.addHiddenApiExemptions("Landroid/content/IClipboard") }
            .onFailure { Log.w(TAG, "Hidden API exemption failed: ${it.message}") }
    }

    /** `true` once Shizuku is connected and granted — the only state [readText] can
     *  actually succeed from. Mirrors [ShizukuManager.State.CONNECTED]. */
    fun isReady(shizukuManager: ShizukuManager?): Boolean =
        shizukuManager?.state?.value == ShizukuManager.State.CONNECTED

    /** Returns the clipboard's current plain-text value, or `null` if it's empty, holds
     *  non-text content, or the read failed for any reason (Shizuku not ready, a
     *  version-specific `IClipboard` shape none of [getPrimaryClipOverloads]' candidates
     *  match, etc. — logged, never thrown). Safe to call from the background. */
    fun readText(): String? = runCatching {
        val binder = SystemServiceHelper.getSystemService("clipboard")
            ?: return null.also { Log.w(TAG, "Unable to get system service: clipboard") }
        val stubClass = Class.forName("android.content.IClipboard\$Stub")
        val clipboard = stubClass.getMethod("asInterface", android.os.IBinder::class.java)
            .invoke(null, ShizukuBinderWrapper(binder))
            ?: return null

        val clip = invokeGetPrimaryClip(clipboard) ?: return null
        val getItemCount = clip.javaClass.getMethod("getItemCount")
        if ((getItemCount.invoke(clip) as Int) == 0) return null
        val description = clip.javaClass.getMethod("getDescription").invoke(clip)
        val hasMimeType = description.javaClass.getMethod("hasMimeType", String::class.java)
        if (hasMimeType.invoke(description, "image/*") as Boolean) return null

        val item = clip.javaClass.getMethod("getItemAt", Int::class.javaPrimitiveType).invoke(clip, 0)
        (item.javaClass.getMethod("getText").invoke(item) as? CharSequence)?.toString()
    }.onFailure { Log.w(TAG, "readText failed: ${it.message}") }.getOrNull()

    /** `IClipboard.getPrimaryClip`'s parameter list has changed across Android versions
     *  (confirmed by reading AOSP source directly, not guessed): `(pkg, userId)` on
     *  Android 12/API 31 (this project's tablet), `(pkg, attributionTag, userId, deviceId)`
     *  on current/API 36+ (this project's phone) — an intermediate 3-arg
     *  `(pkg, attributionTag, userId)` shape existed too on versions in between. Tries each
     *  in turn rather than assuming one, so this works across every Android version this
     *  app supports (`minSdk` 29) without a hardcoded SDK-version branch — mirrors
     *  `TetherHelper`'s own multi-overload fallback for the same kind of hidden-API drift. */
    private fun invokeGetPrimaryClip(clipboard: Any): Any? {
        val cls = clipboard.javaClass
        val attempts: List<() -> Any?> = listOf(
            {
                cls.getMethod(
                    "getPrimaryClip", String::class.java, String::class.java,
                    Int::class.javaPrimitiveType, Int::class.javaPrimitiveType
                ).invoke(clipboard, CALLING_PACKAGE, null, 0, 0)
            },
            {
                cls.getMethod(
                    "getPrimaryClip", String::class.java, String::class.java, Int::class.javaPrimitiveType
                ).invoke(clipboard, CALLING_PACKAGE, null, 0)
            },
            {
                cls.getMethod("getPrimaryClip", String::class.java, Int::class.javaPrimitiveType)
                    .invoke(clipboard, CALLING_PACKAGE, 0)
            }
        )
        for (attempt in attempts) {
            val result = runCatching(attempt)
            if (result.isSuccess) return result.getOrNull()
            if (result.exceptionOrNull() !is NoSuchMethodException) {
                Log.w(TAG, "getPrimaryClip invocation failed: ${result.exceptionOrNull()?.message}")
            }
        }
        Log.w(TAG, "No matching IClipboard.getPrimaryClip overload found on this OS version")
        return null
    }
}
