package dev.vmd1.gossip.features.messages

/** One row of the system SMS provider, as far as threading needs it. */
data class SmsRow(val id: Long, val threadId: Long, val address: String, val body: String, val date: Long, val type: Int, val read: Boolean)

/** Pure helpers for turning SMS provider rows into threads; no Android types, so they are unit-testable. */
object SmsThreading {
    /** `Telephony.Sms.MESSAGE_TYPE_INBOX` is 1; every other type (sent, outbox, queued, failed, draft) is ours. */
    fun isOutgoing(type: Int) = type != 1

    /** Groups [rows] (any order) into threads, newest first, with the unread inbox count per thread. */
    fun group(rows: List<SmsRow>): List<MessageThread> =
        rows.groupBy { it.threadId }.map { (thread, list) ->
            val latest = list.maxBy { it.date }
            MessageThread(
                id = thread.toString(),
                address = list.firstOrNull { it.address.isNotBlank() }?.address ?: "",
                name = null,
                snippet = latest.body.take(120),
                date = latest.date,
                outgoing = isOutgoing(latest.type),
                unread = list.count { !it.read && !isOutgoing(it.type) },
            )
        }.sortedByDescending { it.date }

    /** Compares numbers regardless of formatting: digits only, and the last 10 digits when longer (drops country codes). */
    fun normalize(address: String): String {
        val digits = address.filter { it.isDigit() }
        return if (digits.length >= 7) digits.takeLast(10) else address.trim().lowercase()
    }

    /** A phone number (digits, spaces, `+ - ( )`) of a sane length. Short codes and alphanumeric senders are readable but not sendable. */
    fun isPlausibleAddress(address: String) =
        address.length in 3..20 && address.all { it.isDigit() || it in "+-() " } && address.count { it.isDigit() } >= 3

    /** Sent-log messages that the system provider has not already recorded. Some phones (Samsung) write an SMS sent through
     *  [android.telephony.SmsManager] into the provider themselves, so the same text would otherwise show twice: once as the
     *  provider's row and once as the sent-log entry. A provider row counts as the echo when it is outgoing with the same text
     *  within [windowMs] of the send. */
    fun withoutEchoes(sent: List<ChatMessage>, provider: List<ChatMessage>, windowMs: Long = 120_000): List<ChatMessage> =
        sent.filter { s -> provider.none { it.outgoing && it.body == s.body && kotlin.math.abs(it.date - s.date) <= windowMs } }
}
