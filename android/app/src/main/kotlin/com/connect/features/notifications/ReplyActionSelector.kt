package com.connect.features.notifications

/**
 * Pure selection logic for picking the "reply" action out of a status-bar
 * notification's action list, factored out of [NotificationListenerImpl] so it can be
 * unit tested without the Android framework (a real `Notification.Action`/`RemoteInput`
 * can't be constructed in a local JVM unit test).
 */
object ReplyActionSelector {
    /**
     * Given, for each of a notification's actions in order, how many [android.app.RemoteInput]
     * instances that action carries, returns the index of the first action that can carry a
     * typed reply (chat-style "Reply" actions expose exactly this: an action whose
     * `remoteInputs` is non-empty), or `null` if none do.
     */
    fun findReplyActionIndex(remoteInputCountsByAction: List<Int>): Int? {
        val index = remoteInputCountsByAction.indexOfFirst { it > 0 }
        return if (index >= 0) index else null
    }
}
