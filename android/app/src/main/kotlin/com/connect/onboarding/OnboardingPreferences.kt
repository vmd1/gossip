package com.connect.onboarding

import android.content.Context
import android.content.SharedPreferences

/**
 * Plain (not encrypted) local prefs for onboarding — nothing stored here is sensitive: a
 * completion flag and which [com.connect.features.hotspot.HotspotToggleMechanism.id]
 * this specific device's onboarding "test hotspot methods" step found working. Unlike
 * [com.connect.crypto.TrustedDevicesStore], this never crosses the wire (see
 * `HANDOFF_ONBOARDING_AND_POLISH.md` Phase 2) and holds no key material, so
 * `EncryptedSharedPreferences`'s overhead isn't warranted.
 *
 * The primary constructor takes the [SharedPreferences] interface directly — same
 * testability pattern as [com.connect.crypto.TrustedDevicesStore] — so tests can supply an
 * in-memory fake; the [Context]-taking secondary constructor is what real callers use.
 */
class OnboardingPreferences internal constructor(private val prefs: SharedPreferences) {
    constructor(context: Context) : this(context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))

    var isCompleted: Boolean
        get() = prefs.getBoolean(KEY_COMPLETED, false)
        set(value) = prefs.edit().putBoolean(KEY_COMPLETED, value).apply()

    /** The [com.connect.features.hotspot.HotspotToggleMechanism.id] of whichever mechanism
     *  onboarding's probe step found available on this device, or null if onboarding's
     *  hotspot step hasn't run (or found nothing) yet — [com.connect.features.hotspot.
     *  TetherHelper.setHotspotEnabled] then falls back to trying its full ordered list. */
    var preferredHotspotMechanismId: String?
        get() = prefs.getString(KEY_PREFERRED_HOTSPOT_MECHANISM, null)
        set(value) = prefs.edit().putString(KEY_PREFERRED_HOTSPOT_MECHANISM, value).apply()

    private companion object {
        const val PREFS_NAME = "onboarding_prefs"
        const val KEY_COMPLETED = "completed"
        const val KEY_PREFERRED_HOTSPOT_MECHANISM = "preferred_hotspot_mechanism"
    }
}
