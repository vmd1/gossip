package dev.vmd1.gossip.features.messages

/** One conversation, newest message first in lists. [id] is the backend's own thread identifier. */
data class MessageThread(
    val id: String,
    val address: String,
    val name: String?,
    val snippet: String,
    val date: Long,
    val outgoing: Boolean,
    val unread: Int,
)

/** A person in the phone's contacts, with every number they have. */
data class Contact(val id: String, val name: String, val numbers: List<String>)

data class ChatMessage(val id: String, val date: Long, val outgoing: Boolean, val body: String)

/** What the Mac-facing [MessagesBridge] needs from a message store. Kept behind one interface so the SMS store can be
 *  replaced (e.g. by a Google Messages/RCS bridge) without touching the wire handling. */
interface MessagesBackend {
    enum class Failure { NO_PERMISSION, INVALID, FAILED }

    /** `false` when the permissions this backend needs have not been granted. */
    fun hasPermission(): Boolean

    fun threads(limit: Int): List<MessageThread>
    fun history(threadId: String, limit: Int, before: Long?): List<ChatMessage>

    /** Sends [body] to [address]; returns `null` on success or why it failed. */
    fun send(address: String, body: String): Failure?

    /** The contacts that have a phone number, or `null` when the contacts permission isn't granted. */
    fun contacts(): List<Contact>?

    /** Newest message time, total unread, and the number of threads, for the `messages.state` slot. */
    fun summary(): Summary

    data class Summary(val latest: Long, val unread: Int, val threads: Int)
}
