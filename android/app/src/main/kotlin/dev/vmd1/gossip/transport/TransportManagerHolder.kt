package dev.vmd1.gossip.transport

/**
 * Process-wide access point to the single live [TransportManager] instance owned by
 * [dev.vmd1.gossip.service.SyncForegroundService].
 *
 * [TransportManager] itself is deliberately not a singleton (it takes real
 * collaborators — context, identity, trusted devices, router — as constructor
 * arguments so tests can supply fakes), but some Android system components can't be
 * constructed with our own dependency graph and instead need to look the live instance
 * up after the fact. [android.service.notification.NotificationListenerService] is one:
 * the system instantiates and binds it independently of [SyncForegroundService]'s own
 * lifecycle, so `features.notifications.NotificationListenerImpl` reads the transport
 * (and its [MessageRouter]) from here rather than trying to bind to the foreground
 * service the way UI components do.
 */
object TransportManagerHolder {
    @Volatile
    var instance: TransportManager? = null
}
