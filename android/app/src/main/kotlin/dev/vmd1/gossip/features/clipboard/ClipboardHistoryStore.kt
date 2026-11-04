package dev.vmd1.gossip.features.clipboard

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@Serializable
data class ClipboardHistoryEntry(
    val id: String,
    val text: String,
    val date: Long,
    val pinned: Boolean,
    /** `true` if it arrived from a peer rather than being copied here. */
    val remote: Boolean,
    /** For an image entry: the PNG's file name in the history's image folder (`text` is then a label like "Image 800×600"). */
    val imageFile: String? = null,
    /** For an image entry: SHA-256 of the PNG, so copying the same image again moves it to the top instead of adding it. */
    val digest: String? = null
) {
    val isImage: Boolean get() = imageFile != null
}

/**
 * Searchable, pinnable history of clipboard text, kept on this device only (app-private prefs): never sent to a peer
 * or the relay. On by default; turning it off wipes it. Mirrors the Mac's `ClipboardHistoryStore`. Text and images; an image is
 * a PNG file in [imageDir] (app-private), skipped when there is no folder.
 */
class ClipboardHistoryStore(private val prefs: SharedPreferences, private val imageDir: File? = null) {
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

    /** Records a copied image (PNG bytes, already checked by the caller). The same image again moves to the top; idempotent
     *  for the same bytes. An image over [MAX_IMAGE_BYTES], or with nowhere to store it, is skipped. */
    @Synchronized
    fun recordImage(png: ByteArray, width: Int, height: Int, remote: Boolean, now: Long = System.currentTimeMillis()) {
        val dir = imageDir
        if (!_enabled.value || dir == null || png.isEmpty() || png.size > MAX_IMAGE_BYTES) return
        val digest = MessageDigest.getInstance("SHA-256").digest(png).joinToString("") { "%02x".format(it) }
        val list = _entries.value.toMutableList()
        val i = list.indexOfFirst { it.digest == digest }
        if (i >= 0) {
            list.add(0, list.removeAt(i).copy(date = now))
        } else {
            dir.mkdirs()
            val file = UUID.randomUUID().toString() + ".png"
            if (!runCatching { File(dir, file).writeBytes(png) }.isSuccess) return
            list.add(0, ClipboardHistoryEntry(UUID.randomUUID().toString(), "Image ${width}×$height", now, pinned = false, remote = remote, imageFile = file, digest = digest))
        }
        commit(trim(list))
    }

    /** The PNG bytes of an image entry. */
    fun imageBytes(entry: ClipboardHistoryEntry): ByteArray? =
        entry.imageFile?.let { f -> imageDir?.let { runCatching { File(it, f).readBytes() }.getOrNull() } }

    @Synchronized
    fun togglePin(id: String) {
        commit(trim(_entries.value.map { if (it.id == id) it.copy(pinned = !it.pinned) else it }))
    }

    @Synchronized
    fun remove(id: String) {
        deleteImages(_entries.value.filter { it.id == id })
        commit(_entries.value.filterNot { it.id == id })
    }

    /** Wipes everything, pinned included (and every stored image file). */
    @Synchronized
    fun clear() {
        deleteImages(_entries.value)
        commit(emptyList())
    }

    private fun deleteImages(removed: List<ClipboardHistoryEntry>) {
        val dir = imageDir ?: return
        removed.mapNotNull { it.imageFile }.forEach { runCatching { File(dir, it).delete() } }
    }

    /** Pinned first, then newest; filtered by a case-insensitive substring. */
    fun filtered(query: String): List<ClipboardHistoryEntry> {
        val q = query.trim()
        val matches = if (q.isEmpty()) _entries.value else _entries.value.filter { it.text.contains(q, ignoreCase = true) }
        return matches.filter { it.pinned } + matches.filterNot { it.pinned }
    }

    private fun trim(list: List<ClipboardHistoryEntry>): List<ClipboardHistoryEntry> {
        var kept = 0
        val (keep, drop) = list.partition { it.pinned || ++kept <= MAX_UNPINNED }
        deleteImages(drop)
        return keep
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
        const val MAX_IMAGE_BYTES = 4 * 1024 * 1024
        private const val KEY_ENABLED = "enabled"
        private const val KEY_ENTRIES = "entries"

        @Volatile private var instance: ClipboardHistoryStore? = null

        fun getInstance(context: Context): ClipboardHistoryStore = instance ?: synchronized(this) {
            instance ?: ClipboardHistoryStore(
                context.applicationContext.getSharedPreferences("clipboard_history", Context.MODE_PRIVATE),
                File(context.applicationContext.filesDir, "clipboard-history")
            ).also { instance = it }
        }
    }
}
