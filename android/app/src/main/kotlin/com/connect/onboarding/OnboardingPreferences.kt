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

    /** Whether this **phone** offers itself as an Instant Hotspot source to nearby
     *  requesting devices (see `docs/ble-hotspot-protocol.md`) — a phone-only setting
     *  (tablets/Mac never provide, only request), off by default since it flips on
     *  cellular data and battery use for a phone that might not want to volunteer.
     *  Gates both the BLE advertisement's "hotspot available" capability bit and the
     *  GATT server's willingness to accept a `hotspot.toggle_request` — a phone with
     *  this off should not advertise the capability at all, not just refuse requests
     *  after the fact. Local device policy, never sent over the wire — same category
     *  as [preferredHotspotMechanismId]. */
    var provideHotspotEnabled: Boolean
        get() = prefs.getBoolean(KEY_PROVIDE_HOTSPOT, false)
        set(value) = prefs.edit().putBoolean(KEY_PROVIDE_HOTSPOT, value).apply()

    /** Whether *this* device automatically requests Instant Hotspot from a nearby,
     *  eligible, opted-in phone after being offline (no WAN reachability) for a while —
     *  see `docs/ble-hotspot-protocol.md`'s WAN-reachability probe and
     *  [com.connect.features.hotspot.AutoHotspotRequestManager]. Distinct from the
     *  per-phone [com.connect.crypto.TrustedDevice.autoHotspotRequestEligible] flag: this
     *  is the global on/off switch for *this* device; that flag narrows which trusted
     *  phones are eligible targets once this is on. Off by default, local-only, never
     *  sent over the wire — same category as [provideHotspotEnabled]. Meaningful for any
     *  device type (Mac, tablet, or a phone with no cellular/Wi-Fi of its own), not just
     *  phones, unlike [provideHotspotEnabled]. */
    var autoRequestHotspotEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_REQUEST_HOTSPOT, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_REQUEST_HOTSPOT, value).apply()

    private companion object {
        const val PREFS_NAME = "onboarding_prefs"
        const val KEY_COMPLETED = "completed"
        const val KEY_PREFERRED_HOTSPOT_MECHANISM = "preferred_hotspot_mechanism"
        const val KEY_PROVIDE_HOTSPOT = "provide_hotspot_enabled"
        const val KEY_AUTO_REQUEST_HOTSPOT = "auto_request_hotspot_enabled"
    }
}
