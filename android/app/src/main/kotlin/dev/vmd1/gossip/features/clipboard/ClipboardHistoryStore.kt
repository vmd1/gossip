package dev.vmd1.gossip.features.clipboard

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

@Serializable
data class ClipboardHistoryEntry(
    val id: String,
    val text: String,
    val date: Long,
    val pinned: Boolean,
    /** `true` if it arrived from a peer rather than being copied here. */
    val remote: Boolean
)

/**
 * Searchable, pinnable history of clipboard text, kept on this device only (app-private prefs): never sent to a peer
 * or the relay. On by default; turning it off wipes it. Mirrors the Mac's `ClipboardHistoryStore`. Text only.
 */
class ClipboardHistoryStore(private val prefs: SharedPreferences) {
    private val _entries = MutableStateFlow(load())
    val entries: StateFlow<List<ClipboardHistoryEntry>> = _entries

    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, true))
    val enabled: StateFlow<Boolean> = _enabled

    fun setEnabled(value: Boolean) {
        prefs.edit().putBoolean(KEY_ENABLED, value).apply()
        _enabled.value = value
        if (!value) clear()
    }

    /** Records a copy. Re-copying existing text moves it to the top (keeping its pin); idempotent for the same value. */
    @Synchronized
    fun record(text: String, remote: Boolean, now: Long = System.currentTimeMillis()) {
        if (!_enabled.value || text.isBlank() || text.toByteArray().size > MAX_ENTRY_BYTES) return
        val list = _entries.value.toMutableList()
        val i = list.indexOfFirst { it.text == text }
        if (i >= 0) {
            list.add(0, list.removeAt(i).copy(date = now))
        } else {
            list.add(0, ClipboardHistoryEntry(UUID.randomUUID().toString(), text, now, pinned = false, remote = remote))
        }
        commit(trim(list))
    }

    @Synchronized
    fun togglePin(id: String) {
        commit(trim(_entries.value.map { if (it.id == id) it.copy(pinned = !it.pinned) else it }))
    }

    @Synchronized
    fun remove(id: String) = commit(_entries.value.filterNot { it.id == id })

    /** Wipes everything, pinned included. */
    @Synchronized
    fun clear() = commit(emptyList())

    /** Pinned first, then newest; filtered by a case-insensitive substring. */
    fun filtered(query: String): List<ClipboardHistoryEntry> {
        val q = query.trim()
        val matches = if (q.isEmpty()) _entries.value else _entries.value.filter { it.text.contains(q, ignoreCase = true) }
        return matches.filter { it.pinned } + matches.filterNot { it.pinned }
    }

    private fun trim(list: List<ClipboardHistoryEntry>): List<ClipboardHistoryEntry> {
        var kept = 0
        return list.filter { it.pinned || ++kept <= MAX_UNPINNED }
    }

    private fun commit(list: List<ClipboardHistoryEntry>) {
        _entries.value = list
        prefs.edit().putString(KEY_ENTRIES, Json.encodeToString(list)).apply()
    }

    private fun load(): List<ClipboardHistoryEntry> =
        runCatching { Json.decodeFromString<List<ClipboardHistoryEntry>>(prefs.getString(KEY_ENTRIES, "[]")!!) }
            .getOrDefault(emptyList())

    companion object {
        const val MAX_UNPINNED = 100
        const val MAX_ENTRY_BYTES = 100_000
        private const val KEY_ENABLED = "enabled"
        private const val KEY_ENTRIES = "entries"

        @Volatile private var instance: ClipboardHistoryStore? = null

        fun getInstance(context: Context): ClipboardHistoryStore = instance ?: synchronized(this) {
            instance ?: ClipboardHistoryStore(
                context.applicationContext.getSharedPreferences("clipboard_history", Context.MODE_PRIVATE)
            ).also { instance = it }
        }
    }
}
