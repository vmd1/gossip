package com.connect.protocol

import android.content.Context

/**
 * Determines this device's own [DeviceType] at runtime, rather than hardcoding
 * [DeviceType.ANDROID_PHONE] as every previous call site did. Uses the standard
 * Android tablet heuristic — `smallestScreenWidthDp >= 600` — the same threshold the
 * platform itself uses to select `-sw600dp` resource qualifiers, since there is no
 * dedicated "is this a tablet" API.
 */
fun detectDeviceType(context: Context): DeviceType {
    val smallestWidthDp = context.resources.configuration.smallestScreenWidthDp
    return if (smallestWidthDp >= 600) DeviceType.ANDROID_TABLET else DeviceType.ANDROID_PHONE
}
