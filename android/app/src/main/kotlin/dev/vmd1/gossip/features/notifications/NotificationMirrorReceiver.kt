package dev.vmd1.gossip.features.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Base64
import dev.vmd1.gossip.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import dev.vmd1.gossip.crypto.IdentityKeyStore
import dev.vmd1.gossip.protocol.Envelope
import dev.vmd1.gossip.protocol.MessageType
import dev.vmd1.gossip.transport.EnvelopeHandler
import dev.vmd1.gossip.transport.MessageRouter
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.UUID

private const val TAG = "NotificationMirror"
private const val CHANNEL_ID = "connect_notification_mirror"
private const val MIRROR_NOTIFICATION_ID = 3001
private const val EXTRA_SOURCE_DEVICE_ID = "dev.vmd1.gossip.app.sourceDeviceId"
private const val EXTRA_ORIGINAL_ID = "dev.vmd1.gossip.app.originalNotificationId"
private const val REPLY_RESULT_KEY = "dev.vmd1.gossip.app.notificationReplyText"

/**
 * The receiving/mirroring counterpart to [NotificationListenerImpl]: mirrors a peer
 * device's `notification.posted` / `notification.removed` (sent broadcast, per
 * `schema/message-types.md`, so it reaches every other trusted device — Macs *and*
 * other Android devices) as a local Android notification, and lets the user reply or
 * dismiss it, round-tripping back to the *specific* device that posted the original
 * (`notification.reply` / `notification.dismiss`, targeted, not broadcast — see
 * [sendReply]/[sendDismiss]).
 *
 * Every notification posted here carries [EXTRA_IS_MIRROR] so [NotificationListenerImpl]
 * never re-detects and re-broadcasts it — without that guard, a phone mirroring a
 * tablet's notification would immediately treat its own mirrored copy as new local
 * content and ping-pong it back out to the whole mesh.
 */
class NotificationMirrorReceiver(
    private val context: Context,
    private val transportManager: TransportManager,
    private val identityKeyStore: IdentityKeyStore,
    messageRouter: MessageRouter,
    private val scope: CoroutineScope
) {
    /** Local notification tag for one mirrored notification, encoding both which device
     *  posted it and that device's own `id` for it — mirrors Mac's
     *  `NotificationMirrorManager.localIdentifier(for:sourceDeviceId:)`, and for the same
     *  reason: a bare `id` could collide between two different phones/tablets, and a
     *  reply/dismiss must route back to the specific device that posted the original. */
    private fun localTag(sourceDeviceId: String, originalId: String) = "$sourceDeviceId|$originalId"

    init {
        ensureChannel()
        messageRouter.register(MessageType.NOTIFICATION_POSTED, EnvelopeHandler { handlePosted(it) })
        messageRouter.register(MessageType.NOTIFICATION_REMOVED, EnvelopeHandler { handleRemoved(it) })
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Mirrored notifications",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }
    }

    // MARK: Inbound: notification.posted / notification.removed (broadcast, any mesh member)

    private fun handlePosted(envelope: Envelope) {
        // Never mirror our own notification back onto ourselves — only relevant if this
        // envelope somehow looped back to its own originator (flood-forward's dedupe
        // cache already guards against this in the common case; this is belt-and-suspenders).
        if (envelope.senderId == identityKeyStore.deviceId) return
        val payload = try {
            Json { ignoreUnknownKeys = true }.decodeFromJsonElement(NotificationPostedPayload.serializer(), envelope.payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.posted payload", e)
            return
        }
        postMirroredNotification(sourceDeviceId = envelope.senderId, payload = payload)
    }

    private fun handleRemoved(envelope: Envelope) {
        if (envelope.senderId == identityKeyStore.deviceId) return
        val payload = try {
            Json { ignoreUnknownKeys = true }.decodeFromJsonElement(NotificationRemovedPayload.serializer(), envelope.payload)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to decode notification.removed payload", e)
            return
        }
        NotificationManagerCompat.from(context).cancel(localTag(envelope.senderId, payload.id), MIRROR_NOTIFICATION_ID)
    }

    private fun postMirroredNotification(sourceDeviceId: String, payload: NotificationPostedPayload) {
        val tag = localTag(sourceDeviceId, payload.id)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(if (payload.title.isBlank()) payload.appName else "${payload.appName} · ${payload.title}")
            .setContentText(payload.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(payload.body))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(false)
            .setExtras(android.os.Bundle().apply { putBoolean(EXTRA_IS_MIRROR, true) })

        payload.iconBase64?.let { base64 ->
            runCatching {
                val bytes = Base64.decode(base64, Base64.NO_WRAP)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }.getOrNull()?.let { builder.setLargeIcon(it) }
        }

        builder.setDeleteIntent(dismissPendingIntent(sourceDeviceId, payload.id, tag))

        if (payload.hasReplyAction) {
            val remoteInput = RemoteInput.Builder(REPLY_RESULT_KEY).setLabel("Reply").build()
            val replyAction = NotificationCompat.Action.Builder(
                android.R.drawable.ic_menu_send,
                "Reply",
                replyPendingIntent(sourceDeviceId, payload.id, tag)
            ).addRemoteInput(remoteInput).build()
            builder.addAction(replyAction)
        }

        runCatching {
            NotificationManagerCompat.from(context).notify(tag, MIRROR_NOTIFICATION_ID, builder.build())
        }.onFailure { Log.w(TAG, "Failed to post mirrored notification: ${it.message}") }
    }

    private fun dismissPendingIntent(sourceDeviceId: String, originalId: String, tag: String): PendingIntent {
        val intent = Intent(context, NotificationMirrorDismissReceiver::class.java)
            .putExtra(EXTRA_SOURCE_DEVICE_ID, sourceDeviceId)
            .putExtra(EXTRA_ORIGINAL_ID, originalId)
        return PendingIntent.getBroadcast(
            context,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun replyPendingIntent(sourceDeviceId: String, originalId: String, tag: String): PendingIntent {
        val intent = Intent(context, NotificationMirrorReplyReceiver::class.java)
            .putExtra(EXTRA_SOURCE_DEVICE_ID, sourceDeviceId)
            .putExtra(EXTRA_ORIGINAL_ID, originalId)
        return PendingIntent.getBroadcast(
            context,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
    }

    // MARK: Outbound: notification.reply / notification.dismiss (targeted at the source device)
    // Not private: the two BroadcastReceivers below (instantiated fresh by the system on
    // each broadcast) call these directly via `NotificationMirrorReceiver.instance`.

    internal fun sendReply(sourceDeviceId: String, originalId: String, text: String) {
        val envelope = Envelope(
            type = MessageType.NOTIFICATION_REPLY,
            senderId = identityKeyStore.deviceId,
            recipientId = sourceDeviceId,
            payload = Json.encodeToJsonElement(
                NotificationReplyPayload.serializer(),
                NotificationReplyPayload(id = originalId, text = text, attemptId = UUID.randomUUID().toString())
            ).jsonObject
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send notification.reply: ${it.message}") }
        }
    }

    internal fun sendDismiss(sourceDeviceId: String, originalId: String) {
        val envelope = Envelope(
            type = MessageType.NOTIFICATION_DISMISS,
            senderId = identityKeyStore.deviceId,
            recipientId = sourceDeviceId,
            payload = Json.encodeToJsonElement(NotificationDismissPayload.serializer(), NotificationDismissPayload(id = originalId)).jsonObject
        )
        scope.launch {
            runCatching { transportManager.send(envelope) }
                .onFailure { Log.w(TAG, "Failed to send notification.dismiss: ${it.message}") }
        }
    }

    companion object {
        /** Set once by [dev.vmd1.gossip.service.SyncForegroundService] so the two
         *  [BroadcastReceiver]s below (instantiated fresh by the system on each
         *  broadcast, not by our own dependency graph) can reach this instance —
         *  same pattern as `TransportManagerHolder`. */
        @Volatile
        var instance: NotificationMirrorReceiver? = null
    }
}

/** Fired by the system when the user swipes away a mirrored notification
 *  ([NotificationCompat.Builder.setDeleteIntent]) — forwards `notification.dismiss`
 *  back to whichever device originally posted it. */
class NotificationMirrorDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sourceDeviceId = intent.getStringExtra(EXTRA_SOURCE_DEVICE_ID) ?: return
        val originalId = intent.getStringExtra(EXTRA_ORIGINAL_ID) ?: return
        NotificationMirrorReceiver.instance?.sendDismiss(sourceDeviceId, originalId)
    }
}

/** Fired by the system with the typed reply text ([RemoteInput]) when the user replies
 *  inline to a mirrored notification — forwards `notification.reply` back to whichever
 *  device originally posted it. */
class NotificationMirrorReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sourceDeviceId = intent.getStringExtra(EXTRA_SOURCE_DEVICE_ID) ?: return
        val originalId = intent.getStringExtra(EXTRA_ORIGINAL_ID) ?: return
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_RESULT_KEY)?.toString() ?: return
        NotificationMirrorReceiver.instance?.sendReply(sourceDeviceId, originalId, text)
    }
}
