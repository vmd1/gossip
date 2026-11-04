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
import dev.vmd1.gossip.util.Log
import uniffi.gossip_ffi.ReplyGuard as CoreReplyGuard
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.DeviceType
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.protocol.detectDeviceType
import dev.vmd1.gossip.service.SyncForegroundService
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
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
private const val APP_ICON_SIZE_PX = 96
private const val APP_ICON_CACHE_LIMIT = 128
private const val PICTURE_MAX_EDGE = 512

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

    /** The source notification's other buttons, by the index sent in `notification.posted`'s `actions`. */
    private val actionTargets = ConcurrentHashMap<String, Map<Int, PendingIntent>>()
    private val recentActionAttempts = RecentAttempts()
    private var scope: CoroutineScope? = null

    /** Acts on each `notification.reply` attempt once. A duplicate delivery (retry, relay race, mesh dedupe-cache eviction —
     *  see `docs/wire-protocol.md`'s "De-duplication" section) must not fire the source app's own `PendingIntent` twice, since
     *  that sends the same reply text into a real conversation a second time. The bounded recently-handled cache keyed by the
     *  per-attempt `attemptId` (not the notification `id`, which is reused across distinct replies) is the core's `ReplyGuard`
     *  (`desktop/core/src/features/notifications.rs`), shared with every platform. */
    private val replyGuard = CoreReplyGuard()

    /** packageName -> encoded launcher icon (or null if unavailable); see [appIconBase64]. Bounded. */
    private val appIconCache = object : LinkedHashMap<String, String?>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String?>?) = size > APP_ICON_CACHE_LIMIT
    }

    /** Only phones forward their notifications to the mesh; a tablet (or any other non-phone) shows
     *  mirrored notifications from phones but never sends its own. */
    private val isPhone: Boolean by lazy { detectDeviceType(applicationContext) == DeviceType.ANDROID_PHONE }

    override fun onListenerConnected() {
        super.onListenerConnected()
        dev.vmd1.gossip.features.media.MediaListenerAccess.onConnected?.invoke() // media sessions can now be read
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

        active = this
        ensureHandlersRegistered()
        publishActive()
    }

    private val replyEnvelopeHandler = EnvelopeHandler { envelope -> handleReply(envelope.payload) }
    private val dismissEnvelopeHandler = EnvelopeHandler { envelope -> handleDismiss(envelope.payload) }
    private val actionEnvelopeHandler = EnvelopeHandler { envelope -> handleAction(envelope.payload) }
    private var registeredRouter: MessageRouter? = null

    /**
     * Registers the `notification.reply` / `notification.dismiss` handlers on the live router. The
     * system binds this listener independently of [SyncForegroundService] (e.g. right after the app
     * process restarts), so [TransportManagerHolder.instance] can still be null when
     * [onListenerConnected] runs — previously the handlers were then silently never registered, and
     * dismissing a mirrored notification on the Mac did nothing on the phone. This is idempotent and
     * is retried when the service publishes its transport ([SyncForegroundService]) and on every
     * notification event, so the handlers always end up registered on the *current* router.
     */
    @Synchronized
    fun ensureHandlersRegistered() {
        val router = TransportManagerHolder.instance?.messageRouter ?: return
        if (registeredRouter === router) return
        registeredRouter?.let { old ->
            old.unregister(replyEnvelopeHandler)
            old.unregister(dismissEnvelopeHandler)
            old.unregister(actionEnvelopeHandler)
        }
        router.register(MessageType.NOTIFICATION_REPLY, replyEnvelopeHandler)
        router.register(MessageType.NOTIFICATION_DISMISS, dismissEnvelopeHandler)
        router.register(MessageType.NOTIFICATION_ACTION, actionEnvelopeHandler)
        registeredRouter = router
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        tearDown()
    }

    private fun tearDown() {
        registeredRouter?.let { router ->
            router.unregister(replyEnvelopeHandler)
            router.unregister(dismissEnvelopeHandler)
            router.unregister(actionEnvelopeHandler)
        }
        registeredRouter = null
        if (active === this) active = null
        scope?.cancel()
        scope = null
        replyTargets.clear()
        actionTargets.clear()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)
        if (!isPhone) return
        ensureHandlersRegistered()
        if (!shouldMirror(sbn)) return

        val id = sbn.key
        val notification = sbn.notification
        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()

        val replyAction = findReplyAction(notification)
        if (replyAction != null) {
            replyTargets[id] = ReplyTarget(replyAction.actionIntent, replyAction.remoteInputs!!)
        } else {
            replyTargets.remove(id)
        }

        val buttons = otherActions(notification)
        if (buttons.isEmpty()) actionTargets.remove(id) else actionTargets[id] = buttons.associate { it.first.index to it.second }

        val payload = NotificationPostedPayload(
            id = id,
            appPackage = sbn.packageName,
            appName = appLabel(sbn.packageName),
            title = title,
            body = body,
            iconBase64 = appIconBase64(sbn.packageName),
            hasReplyAction = replyAction != null,
            timestamp = sbn.postTime,
            avatarBase64 = avatarBase64(notification),
            pictureBase64 = pictureBase64(extras),
            actions = buttons.map { it.first }.takeIf { it.isNotEmpty() },
            smartReplies = replyAction?.let { smartReplies(it) }?.takeIf { it.isNotEmpty() },
            live = liveInfo(notification)
        )
        send(payload.toEnvelope(senderId = deviceId()))
    }

    /** Whether [sbn] is one this phone mirrors to the mesh. The same test decides what is sent as
     *  `notification.posted` and what is listed in `notification.sync`, so the two never disagree. */
    private fun shouldMirror(sbn: StatusBarNotification): Boolean {
        // Settings → Notifications → Apps: the user can switch individual apps off.
        if (!NotificationForwardSettings.getInstance(applicationContext).isAllowed(sbn.packageName)) return false
        // Never mirror our own persistent "Gossip is running" foreground-service notification specifically, but DO
        // mirror any other notification this app posts (e.g. a manual "Send Test Notification" button), so that
        // button is actually useful for testing the mirroring pipeline end to end.
        if (sbn.packageName == packageName && sbn.id == SyncForegroundService.NOTIFICATION_ID) return false
        // Never re-mirror a notification this app itself posted to mirror some OTHER device's notification, see
        // EXTRA_IS_MIRROR's doc for why this must be a content-based check, not a package/id exclusion.
        if (sbn.notification.extras.getBoolean(EXTRA_IS_MIRROR, false)) return false
        // An ongoing notification is skipped unless it is a live one (progress, timer, call), which is shown as it updates.
        if (!sbn.isClearable && sbn.notification.flags and Notification.FLAG_ONGOING_EVENT != 0 && liveInfo(sbn.notification) == null) return false
        // Media playback notifications are already covered end to end by the dedicated media.nowplaying and
        // media.command pipeline, so a mirrored copy would just be redundant clutter.
        if (sbn.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return false
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()
        return title.isNotEmpty() || body.isNotEmpty()
    }

    /** Reports which notifications are currently mirrored as the `notification.active` state slot (see
     *  `docs/plans/state-sync.md`): the core sends it to every device that connects later and repairs it periodically, so a
     *  receiver that missed a `notification.removed` drops its copy. Called after every post and removal, and when the
     *  listener connects; a no-op when the list is unchanged. A phone with more than [NotificationSyncPayload.MAX_IDS] active
     *  notifications reports nothing rather than a huge list, and receivers keep what they have. */
    private fun publishActive() {
        if (!isPhone || scope == null) return
        val keys = try {
            activeNotifications?.filter { shouldMirror(it) }?.map { it.key }
        } catch (e: Exception) {
            Log.w(TAG, "Could not list active notifications: ${e.message}")
            null
        } ?: return
        if (keys.size > NotificationSyncPayload.MAX_IDS) return
        TransportManagerHolder.instance?.setState(ACTIVE_SLOT, NotificationSyncPayload(keys).toJson())
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        if (!isPhone) return
        if (!NotificationForwardSettings.getInstance(applicationContext).isAllowed(sbn.packageName)) return
        replyTargets.remove(sbn.key)
        actionTargets.remove(sbn.key)
        val payload = NotificationRemovedPayload(id = sbn.key)
        send(payload.toEnvelope(senderId = deviceId()))
        publishActive()
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
        // `null`: a duplicate attempt, or a reply without the required `attemptId` (nothing to de-duplicate on).
        val reply = try {
            replyGuard.accept(payload.toString())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.reply payload", e)
            return
        } ?: run {
            Log.i(TAG, "Dropping a duplicate or malformed notification.reply")
            return
        }
        val target = replyTargets[reply.notificationId] ?: run {
            Log.w(TAG, "No cached reply target for notification ${reply.notificationId}; can't deliver reply")
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
            Log.w(TAG, "Reply PendingIntent was canceled for notification ${reply.notificationId}", e)
        }
    }

    // MARK: - notification.action (any device -> android)

    private fun handleAction(payload: JsonObject) {
        val action = try {
            NotificationActionPayload.fromPayload(payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.action payload", e)
            return
        }
        // A duplicate delivery must not press the button twice (it can answer a call or archive a message).
        if (!recentActionAttempts.firstTime(action.attemptId)) {
            Log.i(TAG, "Dropping a duplicate notification.action")
            return
        }
        val pending = actionTargets[action.id]?.get(action.index) ?: run {
            Log.w(TAG, "No action ${action.index} cached for notification ${action.id}")
            return
        }
        try {
            pending.send()
        } catch (e: PendingIntent.CanceledException) {
            Log.w(TAG, "Action PendingIntent was canceled for notification ${action.id}", e)
        }
    }

    // MARK: - Helpers

    /** The buttons other than the reply action that can be pressed remotely, with their intents. */
    private fun otherActions(notification: Notification): List<Pair<NotificationActionInfo, PendingIntent>> =
        notification.actions?.toList().orEmpty().mapIndexedNotNull { index, a ->
            val title = a.title?.toString()?.trim().orEmpty()
            val intent = a.actionIntent
            if (title.isEmpty() || intent == null || !a.remoteInputs.isNullOrEmpty()) null
            else NotificationActionInfo(index, title.take(40)) to intent
        }.take(NotificationPostedPayload.MAX_ACTIONS)

    private fun smartReplies(action: Notification.Action): List<String> =
        action.remoteInputs.orEmpty().flatMap { it.choices?.toList().orEmpty() }
            .map { it.toString().trim().take(100) }.filter { it.isNotEmpty() }.distinct()
            .take(NotificationPostedPayload.MAX_SMART_REPLIES)

    private fun liveInfo(n: Notification): NotificationLive? {
        val e = n.extras
        if (n.category == Notification.CATEGORY_CALL) {
            return NotificationLive("call", chronometerBase = if (e.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)) n.`when` else null)
        }
        val max = e.getInt(Notification.EXTRA_PROGRESS_MAX, 0)
        val indeterminate = e.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false)
        if (max > 0 || indeterminate) {
            return NotificationLive("progress", progress = e.getInt(Notification.EXTRA_PROGRESS, 0), max = max, indeterminate = indeterminate)
        }
        if (e.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)) return NotificationLive("timer", chronometerBase = n.`when`)
        return null
    }

    private fun avatarBase64(n: Notification): String? = runCatching {
        val icon = n.getLargeIcon()?.loadDrawable(applicationContext) ?: return null
        Base64.encodeToString(drawableToPngBytes(icon, APP_ICON_SIZE_PX), Base64.NO_WRAP)
    }.getOrNull()

    @Suppress("DEPRECATION")
    private fun pictureBase64(extras: Bundle): String? = runCatching {
        val bmp = (extras.get(Notification.EXTRA_PICTURE) as? Bitmap) ?: return null
        val scale = PICTURE_MAX_EDGE.toFloat() / maxOf(bmp.width, bmp.height)
        val scaled = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt().coerceAtLeast(1), (bmp.height * scale).toInt().coerceAtLeast(1), true) else bmp
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 75, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP).takeIf { it.length <= NotificationPostedPayload.MAX_PICTURE_BASE64_CHARS }
    }.getOrNull()

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

    companion object {
        /** The connected listener instance, so [SyncForegroundService] can nudge it once the transport exists. */
        @Volatile var active: NotificationListenerImpl? = null

        /** The synchronised state slot listing the notifications this phone is mirroring. */
        const val ACTIVE_SLOT = "notification.active"
    }
}
