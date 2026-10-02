package dev.vmd1.gossip.features.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.TransportManagerHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "NotificationListener"
private const val REPLY_DEDUPE_CACHE_LIMIT = 128
private const val APP_ICON_SIZE_PX = 96
private const val APP_ICON_CACHE_LIMIT = 128

/**
 * Bridges the Android [NotificationListenerService] special-access API into the
 * Connect wire protocol: mirrors every non-Connect status-bar notification to the Mac
 * as `notification.posted` / `notification.removed`, and lets the Mac reply through a
 * chat notification's own [RemoteInput] via `notification.reply`.
 *
 * The system binds/unbinds this service independently of [dev.vmd1.gossip.service.SyncForegroundService],
 * so it reaches the live [dev.vmd1.gossip.transport.TransportManager] through
 * [TransportManagerHolder] rather than a direct constructor reference (see that file's
 * doc comment for why).
 *
 * Requires the user to grant special "Notification access" in system Settings — see
 * `Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS`, deep-linked from the app's onboarding
 * UI, since this permission cannot be requested through a normal runtime dialog.
 */
class NotificationListenerImpl : NotificationListenerService() {

    /** Everything needed to deliver a reply back through the *original* notification's
     *  own reply action, keyed by the same `id` we sent in `notification.posted`. We
     *  cache this at post-time because [StatusBarNotification]/`PendingIntent` can't be
     *  re-queried later by id once the system notification is gone. */
    private data class ReplyTarget(val pendingIntent: PendingIntent, val remoteInputs: Array<RemoteInput>)

    private val replyTargets = ConcurrentHashMap<String, ReplyTarget>()
    private var scope: CoroutineScope? = null
    private var replyHandler: EnvelopeHandler? = null
    private var dismissHandler: EnvelopeHandler? = null

    /** Bounded, size-capped cache of recently-handled `notification.reply` [NotificationReplyPayload.attemptId]s.
     *  A duplicate delivery (retry, relay race, mesh dedupe-cache eviction — see
     *  `docs/wire-protocol.md`'s "De-duplication" section) must not fire the source app's
     *  own `PendingIntent` twice, since that sends the same reply text into a real
     *  conversation a second time. Mirrors `TransportManager.recentEnvelopeIds`/`recordSeen`. */
    /** packageName -> encoded launcher icon (or null if unavailable); see [appIconBase64]. Bounded. */
    private val appIconCache = object : LinkedHashMap<String, String?>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String?>?) = size > APP_ICON_CACHE_LIMIT
    }

    private val dedupeLock = Any()
    private val recentReplyAttemptIds = ArrayDeque<String>()
    private val recentReplyAttemptIdSet = HashSet<String>()

    /** Returns `true` the first time [attemptId] is seen (caller should act on it), `false`
     *  for a repeat (caller should drop it as a no-op). */
    private fun recordReplyAttemptSeen(attemptId: String): Boolean = synchronized(dedupeLock) {
        if (!recentReplyAttemptIdSet.add(attemptId)) return@synchronized false
        recentReplyAttemptIds.addLast(attemptId)
        if (recentReplyAttemptIds.size > REPLY_DEDUPE_CACHE_LIMIT) {
            val evicted = recentReplyAttemptIds.removeFirst()
            recentReplyAttemptIdSet.remove(evicted)
        }
        true
    }

    /** Only phones forward their notifications to the mesh; a tablet (or any other non-phone) shows
     *  mirrored notifications from phones but never sends its own. */
    private val isPhone: Boolean by lazy { detectDeviceType(applicationContext) == DeviceType.ANDROID_PHONE }

    override fun onListenerConnected() {
        super.onListenerConnected()
        if (!isPhone) {
            Log.i(TAG, "Not a phone — notification forwarding disabled on this device")
            return
        }
        // The system can call this while already connected (its own base-class doc warns
        // "this can result in duplicate events") — observed directly in testing, where it
        // registered a second `replyHandler` alongside the first and doubled every
        // outgoing `notification.posted`. Tear down any existing registration first so a
        // redundant connect is idempotent rather than additive.
        if (scope != null) {
            Log.w(TAG, "onListenerConnected called while already connected; resetting")
            tearDown()
        }

        val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = serviceScope

        val handler = EnvelopeHandler { envelope -> handleReply(envelope.payload) }
        replyHandler = handler
        TransportManagerHolder.instance?.messageRouter?.register(MessageType.NOTIFICATION_REPLY, handler)

        val dismiss = EnvelopeHandler { envelope -> handleDismiss(envelope.payload) }
        dismissHandler = dismiss
        TransportManagerHolder.instance?.messageRouter?.register(MessageType.NOTIFICATION_DISMISS, dismiss)
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        tearDown()
    }

    private fun tearDown() {
        replyHandler?.let { TransportManagerHolder.instance?.messageRouter?.unregister(it) }
        replyHandler = null
        dismissHandler?.let { TransportManagerHolder.instance?.messageRouter?.unregister(it) }
        dismissHandler = null
        scope?.cancel()
        scope = null
        replyTargets.clear()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)
        if (!isPhone) return
        // Settings → Notifications → Apps: the user can switch individual apps off.
        if (!NotificationForwardSettings.getInstance(applicationContext).isAllowed(sbn.packageName)) return
        // Never mirror our own persistent "Gossip is running" foreground-service
        // notification specifically — but DO mirror any other notification this app
        // posts (e.g. a manual "Send Test Notification" button), so that button is
        // actually useful for testing the mirroring pipeline end to end.
        if (sbn.packageName == packageName && sbn.id == SyncForegroundService.NOTIFICATION_ID) return
        // Never re-mirror a notification this app itself posted to mirror some OTHER
        // device's notification — see EXTRA_IS_MIRROR's doc for why this must be a
        // content-based check, not a package/id exclusion like the one above.
        if (sbn.notification.extras.getBoolean(EXTRA_IS_MIRROR, false)) return
        if (!sbn.isClearable && sbn.notification.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        // Media playback notifications (Spotify, YouTube Music, etc.) are already covered
        // end to end by the dedicated media.nowplaying/media.command pipeline
        // (MediaControlBridge -> Mac's NowPlayingView), which has real transport controls
        // and updates live with playback position — a mirrored copy of the notification
        // itself would just be redundant clutter, and would re-post on every playback
        // tick as the notification's progress/timestamp changes. `EXTRA_MEDIA_SESSION` is
        // the same signal the system itself uses to identify a `MediaStyle` notification.
        if (sbn.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return

        val id = sbn.key
        val notification = sbn.notification
        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && body.isEmpty()) return

        val replyAction = findReplyAction(notification)
        if (replyAction != null) {
            replyTargets[id] = ReplyTarget(replyAction.actionIntent, replyAction.remoteInputs!!)
        } else {
            replyTargets.remove(id)
        }

        val payload = NotificationPostedPayload(
            id = id,
            appPackage = sbn.packageName,
            appName = appLabel(sbn.packageName),
            title = title,
            body = body,
            iconBase64 = appIconBase64(sbn.packageName),
            hasReplyAction = replyAction != null,
            timestamp = sbn.postTime
        )
        send(payload.toEnvelope(senderId = deviceId()))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        if (!isPhone) return
        if (!NotificationForwardSettings.getInstance(applicationContext).isAllowed(sbn.packageName)) return
        replyTargets.remove(sbn.key)
        val payload = NotificationRemovedPayload(id = sbn.key)
        send(payload.toEnvelope(senderId = deviceId()))
    }

    // MARK: - notification.dismiss (mac -> android)

    /** [cancelNotification] is the same special capability `BIND_NOTIFICATION_LISTENER_SERVICE`
     *  grants for snooze/dismiss features — it can clear another app's notification, which a
     *  normal app has no way to do. Clearing it here also fires our own [onNotificationRemoved],
     *  which sends `notification.removed` straight back to the Mac; harmless (it just no-ops
     *  removing an already-removed mirrored notification), not a loop, since the Mac never
     *  reacts to `notification.removed` by dismissing anything itself. */
    private fun handleDismiss(payload: JsonObject) {
        val dismiss = try {
            NotificationDismissPayload.fromPayload(payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.dismiss payload", e)
            return
        }
        cancelNotification(dismiss.id)
    }

    // MARK: - notification.reply (mac -> android)

    private fun handleReply(payload: JsonObject) {
        val reply = try {
            NotificationReplyPayload.fromPayload(payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.reply payload", e)
            return
        }
        if (!recordReplyAttemptSeen(reply.attemptId)) {
            Log.i(TAG, "Dropping duplicate delivery of reply attempt ${reply.attemptId} for notification ${reply.id}")
            return
        }
        val target = replyTargets[reply.id] ?: run {
            Log.w(TAG, "No cached reply target for notification ${reply.id}; can't deliver reply")
            return
        }
        try {
            val resultsBundle = Bundle()
            for (remoteInput in target.remoteInputs) {
                resultsBundle.putCharSequence(remoteInput.resultKey, reply.text)
            }
            val fillInIntent = Intent()
            RemoteInput.addResultsToIntent(target.remoteInputs, fillInIntent, resultsBundle)
            target.pendingIntent.send(applicationContext, 0, fillInIntent)
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "Reply PendingIntent was canceled for notification ${reply.id}", e)
        }
    }

    // MARK: - Helpers

    private fun findReplyAction(notification: Notification): Notification.Action? =
        notification.actions?.toList().orEmpty().let { actions ->
            val remoteInputCounts = actions.map { it.remoteInputs?.size ?: 0 }
            ReplyActionSelector.findReplyActionIndex(remoteInputCounts)?.let { actions[it] }
        }

    private fun appLabel(packageName: String): String = try {
        val appInfo = packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
        packageManager.getApplicationLabel(appInfo).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        packageName
    }

    /** The source app's launcher icon as a [APP_ICON_SIZE_PX]-px PNG, base64-encoded — what receiving
     *  devices show as the notification's image. (This used to be the notification's *small* icon,
     *  which is a white single-colour status-bar glyph and rendered as a blank square on the Mac/tablet.)
     *  Encoded once per app and cached, since the same few apps notify over and over; a `null` result
     *  (icon couldn't be loaded) is cached too so a bad app isn't retried on every notification. */
    private fun appIconBase64(packageName: String): String? = synchronized(appIconCache) {
        if (appIconCache.containsKey(packageName)) return@synchronized appIconCache[packageName]
        val encoded = try {
            val drawable: Drawable = packageManager.getApplicationIcon(packageName)
            Base64.encodeToString(drawableToPngBytes(drawable, APP_ICON_SIZE_PX), Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
        appIconCache[packageName] = encoded
        encoded
    }

    private fun drawableToPngBytes(drawable: Drawable, sizePx: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, sizePx, sizePx)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun send(envelope: Envelope) {
        val transportManager = TransportManagerHolder.instance
        if (transportManager == null) {
            Log.w(TAG, "Dropping ${envelope.type}: TransportManagerHolder.instance is null")
            return
        }
        val scope = scope
        if (scope == null) {
            Log.w(TAG, "Dropping ${envelope.type}: listener scope is null (onListenerConnected not called yet?)")
            return
        }
        scope.launch {
            try {
                transportManager.send(envelope)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send ${envelope.type}: ${e.message}")
            }
        }
    }

    private fun deviceId(): String = TransportManagerHolder.instance?.identityKeyStore?.deviceId.orEmpty()
}
