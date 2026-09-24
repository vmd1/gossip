package com.connect.features.proximity

import android.app.admin.DeviceAdminReceiver

/**
 * Minimal device-admin receiver — its only purpose is to exist so
 * [android.app.admin.DevicePolicyManager.lockNow] is callable at all (Android requires the
 * calling app to be an active device admin for that specific call). No policies beyond
 * `force-lock` are declared (see res/xml/device_admin.xml), and none of the optional
 * callbacks (onEnabled/onDisabled/onPasswordChanged/...) are overridden — Connect doesn't
 * need to react to admin-state changes, only to be granted the capability once via the
 * one-time onboarding flow (`DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN`, see
 * `ui/MainActivity.kt`), the same pattern as the existing notification-access/DND-access
 * onboarding buttons.
 */
class ConnectDeviceAdminReceiver : DeviceAdminReceiver()
