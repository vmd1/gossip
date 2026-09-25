package dev.vmd1.gossip.features.media

import android.service.notification.NotificationListenerService

/**
 * A `NotificationListenerService` whose sole purpose is to hold notification-listener
 * access so [android.media.session.MediaSessionManager.getActiveSessions] can be called
 * with this service's `ComponentName` (that access is required by the platform even
 * though this service does nothing with the notifications it's handed).
 *
 * The user must grant this via Settings > Notification access, same as any other
 * notification-listener. `MediaControlBridge` treats a `SecurityException` from
 * `getActiveSessions` as "not granted yet" and simply reports no active sessions,
 * rather than crashing.
 */
class MediaNotificationListenerService : NotificationListenerService()
