package dev.vmd1.gossip.features.notifications

/**
 * What this device believes about the notifications it mirrors from other devices, apart from `NotificationManager` so
 * the reconciliation rules can be tested. Thread-safe. Same rules as the Mac's `NotificationMirrorBook`:
 * - a `notification.removed` lost to a disconnect is repaired by the phone's `notification.sync` (anything shown here
 *   for more than [SYNC_GRACE_MS] that the phone no longer lists is removed);
 * - a `notification.posted` that arrives after its own removal is dropped (its timestamp, the sender's clock, is not
 *   later than the removal's);
 * - applying the same sync twice changes nothing.
 */
class MirrorBook {
    private val lock = Any()
    private val shown = object : LinkedHashMap<String, Long>(64, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > MAX_TRACKED
    }
    private val removedAt = object : LinkedHashMap<String, Long>(64, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > MAX_TRACKED
    }

    fun recordShown(tag: String, nowMs: Long) = synchronized(lock) { shown[tag] = nowMs; Unit }

    /** The sender removed it; [ts] is the removal envelope's timestamp. */
    fun recordRemoval(tag: String, ts: Long) = synchronized(lock) {
        removedAt[tag] = maxOf(removedAt[tag] ?: Long.MIN_VALUE, ts)
        shown.remove(tag)
        Unit
    }

    fun isStale(tag: String, postedAt: Long): Boolean = synchronized(lock) {
        val removed = removedAt[tag] ?: return false
        postedAt <= removed
    }

    /** Tags from the sender (those starting with [prefix]) to remove for a sync listing [liveTags]. */
    fun applySync(prefix: String, liveTags: Set<String>, nowMs: Long): List<String> = synchronized(lock) {
        val gone = shown.filter { (tag, at) -> tag.startsWith(prefix) && tag !in liveTags && nowMs - at > SYNC_GRACE_MS }.keys.toList()
        gone.forEach { shown.remove(it) }
        gone
    }

    companion object {
        const val MAX_TRACKED = 512

        /** A notification shown more recently than this is never pruned by a sync (it may be newer than the snapshot). */
        const val SYNC_GRACE_MS = 10_000L
    }
}
