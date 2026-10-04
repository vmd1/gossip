package dev.vmd1.gossip.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map

/**
 * Emits the set of device ids that just appeared in a connected-peers flow — i.e. each
 * *newly connected* peer, even when other peers were already connected (which an aggregate
 * "any peer connected" state can't see). Empty diffs (a peer left, or the same set repeated)
 * are not emitted. Used to fire per-peer initial syncs.
 */
fun Flow<Set<String>>.newlyConnectedPeers(): Flow<Set<String>> {
    var known: Set<String> = emptySet()
    return map { current ->
        val added = current - known
        known = current
        added
    }.filter { it.isNotEmpty() }
}
