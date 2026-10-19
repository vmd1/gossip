package dev.vmd1.gossip.features.messages

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import dev.vmd1.gossip.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val TAG = "SmsBackend"

/**
 * Plain SMS read from the system provider and sent with [SmsManager]. **SMS only**: MMS and RCS conversations are not
 * included. A non-default SMS app cannot write to the provider, so messages sent from the Mac are remembered in
 * [SentLog] and merged into the history.
 */
class SmsBackend(private val context: Context, private val sentLog: SentLog = SentLog(context)) : MessagesBackend {
    override fun hasPermission() =
        granted(Manifest.permission.READ_SMS) && granted(Manifest.permission.SEND_SMS)

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    override fun threads(limit: Int): List<MessageThread> {
        if (!hasPermission()) return emptyList()
        val rows = mutableListOf<SmsRow>()
        runCatching {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ),
                null, null, "${Telephony.Sms.DATE} DESC LIMIT 3000"
            )?.use { c ->
                while (c.moveToNext()) {
                    rows += SmsRow(c.getLong(0), c.getLong(1), c.getString(2) ?: "", c.getString(3) ?: "", c.getLong(4), c.getInt(5), c.getInt(6) == 1)
                }
            }
        }.onFailure { Log.w(TAG, "thread query failed: ${it.message}") }
        val fromProvider = SmsThreading.group(rows)
        // Threads that so far only exist in the sent log (a first message from the Mac to a new number).
        val known = fromProvider.map { SmsThreading.normalize(it.address) }.toSet()
        val extra = sentLog.all().groupBy { SmsThreading.normalize(it.address) }
            .filterKeys { it !in known }
            .map { (_, list) ->
                val latest = list.maxBy { it.date }
                MessageThread("sent:${SmsThreading.normalize(latest.address)}", latest.address, null, latest.body.take(120), latest.date, true, 0)
            }
        // A sent-log entry newer than the provider's last message in that thread updates the snippet.
        val merged = fromProvider.map { t ->
            val newer = sentLog.all().filter { SmsThreading.normalize(it.address) == SmsThreading.normalize(t.address) && it.date > t.date }.maxByOrNull { it.date }
            if (newer != null) t.copy(snippet = newer.body.take(120), date = newer.date, outgoing = true) else t
        }
        return (merged + extra).sortedByDescending { it.date }.take(limit).map { it.copy(name = it.name ?: contactName(it.address)) }
    }

    override fun history(threadId: String, limit: Int, before: Long?): List<ChatMessage> {
        if (!hasPermission()) return emptyList()
        val out = mutableListOf<ChatMessage>()
        var address: String? = null
        if (!threadId.startsWith("sent:")) {
            val id = threadId.toLongOrNull() ?: return emptyList()
            runCatching {
                val where = buildString {
                    append("${Telephony.Sms.THREAD_ID} = ?")
                    if (before != null) append(" AND ${Telephony.Sms.DATE} < ?")
                }
                val args = if (before != null) arrayOf(id.toString(), before.toString()) else arrayOf(id.toString())
                context.contentResolver.query(
                    Telephony.Sms.CONTENT_URI,
                    arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
                    where, args, "${Telephony.Sms.DATE} DESC LIMIT $limit"
                )?.use { c ->
                    while (c.moveToNext()) {
                        address = address ?: c.getString(1)
                        out += ChatMessage("sms-${c.getLong(0)}", c.getLong(3), SmsThreading.isOutgoing(c.getInt(4)), c.getString(2) ?: "")
                    }
                }
            }.onFailure { Log.w(TAG, "history query failed: ${it.message}") }
        } else {
            address = threadId.removePrefix("sent:")
        }
        val norm = address?.let(SmsThreading::normalize)
        if (norm != null) {
            sentLog.all().filter { SmsThreading.normalize(it.address) == norm && (before == null || it.date < before) }
                .forEach { out += ChatMessage(it.id, it.date, true, it.body) }
        }
        return out.sortedByDescending { it.date }.take(limit)
    }

    override fun send(address: String, body: String): MessagesBackend.Failure? {
        if (!hasPermission()) return MessagesBackend.Failure.NO_PERMISSION
        val to = address.trim()
        if (!SmsThreading.isPlausibleAddress(to) || body.isBlank()) return MessagesBackend.Failure.INVALID
        return runCatching {
            val sms = context.getSystemService(SmsManager::class.java)
            sms.sendMultipartTextMessage(to, null, sms.divideMessage(body), null, null)
            sentLog.add(SentLog.Entry("gossip-${System.nanoTime()}", to, body, System.currentTimeMillis()))
            null
        }.getOrElse {
            Log.w(TAG, "send failed: ${it.message}")
            MessagesBackend.Failure.FAILED
        }
    }

    override fun contacts(): List<Contact>? {
        if (!granted(Manifest.permission.READ_CONTACTS)) return null
        val byId = LinkedHashMap<String, Pair<String, MutableList<String>>>()
        runCatching {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                ),
                null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC"
            )?.use { c ->
                while (c.moveToNext()) {
                    val number = c.getString(2)?.trim().orEmpty()
                    val name = c.getString(1)?.trim().orEmpty()
                    if (number.isEmpty() || name.isEmpty()) continue
                    val entry = byId.getOrPut(c.getString(0)) { name to mutableListOf() }
                    if (number !in entry.second) entry.second += number
                }
            }
        }.onFailure { Log.w(TAG, "contacts query failed: ${it.message}") }
        return byId.map { (id, v) -> Contact(id, v.first, v.second.take(6)) }
    }

    override fun summary(): MessagesBackend.Summary {
        if (!hasPermission()) return MessagesBackend.Summary(0, 0, 0)
        var unread = 0
        runCatching {
            context.contentResolver.query(
                Telephony.Sms.Inbox.CONTENT_URI, arrayOf(Telephony.Sms._ID), "${Telephony.Sms.READ} = 0", null, null
            )?.use { unread = it.count }
        }
        val all = threads(100)
        return MessagesBackend.Summary(all.maxOfOrNull { it.date } ?: 0L, unread, all.size)
    }

    private fun contactName(address: String): String? {
        if (!granted(Manifest.permission.READ_CONTACTS) || address.isBlank()) return null
        return runCatching {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address))
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull()
    }
}

/** Messages sent from the Mac, remembered because a non-default SMS app cannot write them to the system provider. */
class SentLog(context: Context) {
    @Serializable data class Entry(val id: String, val address: String, val body: String, val date: Long)

    private val prefs = context.applicationContext.getSharedPreferences("messages_sent_log", Context.MODE_PRIVATE)

    @Synchronized fun all(): List<Entry> =
        runCatching { Json.decodeFromString<List<Entry>>(prefs.getString("entries", "[]")!!) }.getOrDefault(emptyList())

    @Synchronized fun add(entry: Entry) {
        val list = (all() + entry).takeLast(MAX)
        prefs.edit().putString("entries", Json.encodeToString(list)).apply()
    }

    @Synchronized fun clear() { prefs.edit().remove("entries").apply() }

    companion object { const val MAX = 300 }
}
