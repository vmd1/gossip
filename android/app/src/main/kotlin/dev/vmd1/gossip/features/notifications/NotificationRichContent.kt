package dev.vmd1.gossip.features.notifications

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.os.Build
import android.service.notification.NotificationListenerService
import android.util.Base64
import androidx.core.app.NotificationCompat
import dev.vmd1.gossip.util.Log
import java.io.ByteArrayOutputStream

private const val TAG = "NotificationRich"
private const val AVATAR_PX = 96
private const val PICTURE_MAX_PX = 480
private const val MAX_ACTIONS = 3
private const val MAX_SMART_REPLIES = 3

/**
 * The parts of a notification beyond its text that the Mac shows: the sender's photo, an attached image, the app's own
 * buttons, suggested replies and the live state of an ongoing notification. Each part is best effort: an image the
 * listener may not read (another app's content URI) is skipped, never an error.
 */
object NotificationRichContent {

    /** The last message's sender photo (MessagingStyle), else the large icon most apps set to the contact's photo. */
    fun avatarBase64(context: Context, notification: Notification): String? {
        val style = runCatching { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notification) }.getOrNull()
        val personIcon = style?.messages?.lastOrNull()?.person?.icon?.let { icon ->
            runCatching { icon.loadDrawable(context) }.getOrNull()
        }
        val drawable = personIcon ?: notification.getLargeIcon()?.let { load(context, it) } ?: return null
        Log.d(TAG, "avatar from ${if (personIcon != null) "person" else "large icon"}")
        return encode(scaledSquare(drawable, AVATAR_PX), Bitmap.CompressFormat.PNG, 100)
    }

    /** BigPicture's image, else the last message's image when its URI is readable. Downscaled to [PICTURE_MAX_PX]. */
    fun pictureBase64(context: Context, notification: Notification): String? {
        val extras = notification.extras
        @Suppress("DEPRECATION") // the typed overload is API 33+, and this runs from 29
        val bitmap = extras.getParcelable<Bitmap>(Notification.EXTRA_PICTURE)
            ?: (if (Build.VERSION.SDK_INT >= 31) @Suppress("DEPRECATION") extras.getParcelable<Icon>(Notification.EXTRA_PICTURE_ICON) else null)
                ?.let { load(context, it)?.let(::toBitmap) }
            ?: messageImage(context, notification)
            ?: return null
        return encode(scaledToFit(bitmap, PICTURE_MAX_PX), Bitmap.CompressFormat.JPEG, 70)
    }

    private fun messageImage(context: Context, notification: Notification): Bitmap? {
        val style = runCatching { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notification) }.getOrNull()
        val message = style?.messages?.lastOrNull() ?: return null
        val uri = message.dataUri ?: return null
        if (message.dataMimeType?.startsWith("image/") != true) return null
        return try {
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
        } catch (e: Exception) {
            Log.d(TAG, "message image not readable: ${e.javaClass.simpleName}") // usually granted to System UI only
            null
        }
    }

    /** The app's buttons that need no typed input; the reply action has its own path. */
    fun actions(notification: Notification): List<NotificationActionInfo>? =
        notification.actions?.withIndex()
            ?.filter { (_, action) -> action.remoteInputs.isNullOrEmpty() && !action.title.isNullOrBlank() }
            ?.take(MAX_ACTIONS)
            ?.map { (index, action) -> NotificationActionInfo(index, action.title.toString().take(40)) }
            ?.takeIf { it.isNotEmpty() }

    /** The app's own canned replies (`RemoteInput.choices`), then the system's smart replies for this notification. */
    fun smartReplies(notification: Notification, ranking: NotificationListenerService.Ranking?, replyAction: Notification.Action?): List<String>? {
        val choices = replyAction?.remoteInputs?.flatMap { it.choices?.toList().orEmpty() }.orEmpty()
        val suggested = ranking?.smartReplies.orEmpty()
        return (choices + suggested).map { it.toString().trim().take(60) }.filter { it.isNotEmpty() }.distinct()
            .take(MAX_SMART_REPLIES).takeIf { it.isNotEmpty() }
    }

    /** The live state of an ongoing (or progress) notification, or `null` when it is not one to follow. */
    fun live(notification: Notification): NotificationLiveInfo? {
        val extras = notification.extras
        val promoted = Build.VERSION.SDK_INT >= 36 && notification.flags and Notification.FLAG_PROMOTED_ONGOING != 0
        val progressMax = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0)
        val indeterminate = extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false)
        val chronometer = extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false)
        val ongoing = notification.flags and Notification.FLAG_ONGOING_EVENT != 0
        if (!ongoing && progressMax <= 0) return null
        if (!NotificationLiveInfo.qualifies(promoted, notification.category, progressMax, indeterminate, chronometer)) return null
        return NotificationLiveInfo(
            category = notification.category,
            progress = extras.getInt(Notification.EXTRA_PROGRESS, 0).takeIf { progressMax > 0 },
            progressMax = progressMax.takeIf { it > 0 },
            indeterminate = indeterminate,
            chronometerBaseMs = notification.`when`.takeIf { chronometer && it > 0 },
            countDown = extras.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN, false),
            promoted = promoted
        )
    }

    private fun load(context: Context, icon: Icon): Drawable? = try {
        icon.loadDrawable(context)
    } catch (e: Exception) {
        Log.d(TAG, "icon not readable: ${e.javaClass.simpleName}")
        null
    }

    private fun toBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) return drawable.bitmap
        val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: PICTURE_MAX_PX
        val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: PICTURE_MAX_PX
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, width, height)
        drawable.draw(canvas)
        return bitmap
    }

    private fun scaledSquare(drawable: Drawable, size: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return bitmap
    }

    private fun scaledToFit(bitmap: Bitmap, maxPx: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= maxPx) return bitmap
        val scale = maxPx.toFloat() / longest
        return Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1), true)
    }

    private fun encode(bitmap: Bitmap, format: Bitmap.CompressFormat, quality: Int): String? = try {
        val stream = ByteArrayOutputStream()
        bitmap.compress(format, quality, stream)
        Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }
}
