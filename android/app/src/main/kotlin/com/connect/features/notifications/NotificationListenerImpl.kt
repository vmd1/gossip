package com.connect.features.notifications

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
import com.connect.protocol.Envelope
import com.connect.protocol.MessageType
import com.connect.transport.EnvelopeHandler
import com.connect.transport.TransportManagerHolder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "NotificationListener"

/**
 * Bridges the Android [NotificationListenerService] special-access API into the
 * Connect wire protocol: mirrors every non-Connect status-bar notification to the Mac
 * as `notification.posted` / `notification.removed`, and lets the Mac reply through a
 * chat notification's own [RemoteInput] via `notification.reply`.
 *
 * The system binds/unbinds this service independently of [com.connect.service.SyncForegroundService],
 * so it reaches the live [com.connect.transport.TransportManager] through
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

    override fun onListenerConnected() {
        super.onListenerConnected()
        val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = serviceScope

        val handler = EnvelopeHandler { envelope -> handleReply(envelope.payload) }
        replyHandler = handler
        TransportManagerHolder.instance?.messageRouter?.register(MessageType.NOTIFICATION_REPLY, handler)
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        replyHandler?.let { TransportManagerHolder.instance?.messageRouter?.unregister(it) }
        replyHandler = null
        scope?.cancel()
        scope = null
        replyTargets.clear()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)
        if (sbn.packageName == packageName) return // never mirror our own "Connect is running" notification
        if (!sbn.isClearable && sbn.notification.flags and Notification.FLAG_ONGOING_EVENT != 0) return

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
            iconBase64 = smallIconBase64(notification),
            hasReplyAction = replyAction != null,
            timestamp = sbn.postTime
        )
        send(payload.toEnvelope(senderId = deviceId(), recipientId = remoteDeviceId()))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        replyTargets.remove(sbn.key)
        val payload = NotificationRemovedPayload(id = sbn.key)
        send(payload.toEnvelope(senderId = deviceId(), recipientId = remoteDeviceId()))
    }

    // MARK: - notification.reply (mac -> android)

    private fun handleReply(payload: JsonObject) {
        val reply = try {
            NotificationReplyPayload.fromPayload(payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.reply payload", e)
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

    private fun smallIconBase64(notification: Notification): String? = try {
        val drawable: Drawable? = notification.smallIcon?.loadDrawable(this)
        drawable?.let { Base64.encodeToString(drawableToPngBytes(it), Base64.NO_WRAP) }
    } catch (e: Exception) {
        null
    }

    private fun drawableToPngBytes(drawable: Drawable): ByteArray {
        val width = drawable.intrinsicWidth.coerceAtLeast(1)
        val height = drawable.intrinsicHeight.coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun send(envelope: Envelope) {
        val transportManager = TransportManagerHolder.instance ?: return
        scope?.launch {
            try {
                transportManager.send(envelope)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send ${envelope.type}: ${e.message}")
            }
        }
    }

    private fun deviceId(): String = TransportManagerHolder.instance?.identityKeyStore?.deviceId.orEmpty()

    private fun remoteDeviceId(): String? = TransportManagerHolder.instance?.currentRemoteDeviceId()
}
