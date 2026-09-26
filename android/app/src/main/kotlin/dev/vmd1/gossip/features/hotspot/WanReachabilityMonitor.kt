package dev.vmd1.gossip.features.hotspot

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

private const val TAG = "WanReachabilityMonitor"

/**
 * Periodic real internet/WAN reachability probe, distinct from the mesh's own
 * `connectionState`/heartbeat machinery (which only tells you whether a mesh *peer* is
 * reachable, not whether this device has a working internet path at all) — see
 * `docs/ble-hotspot-protocol.md`'s "Not yet built" section for the original design intent
 * this implements.
 *
 * Probes a raw TCP connect to `1.1.1.1:443` (Cloudflare's resolver — a fixed IP, not a
 * hostname, so this never depends on DNS working) rather than ICMP ping, which needs a
 * permission/root Android doesn't grant a normal app.
 *
 * Fires [wentOffline] **once** per offline episode (edge-triggered, mirroring
 * [dev.vmd1.gossip.features.proximity.LockOnLeaveManager]'s "once per transition, not every
 * tick" convention) after both:
 * - [OFFLINE_THRESHOLD_MS] (1 minute) have elapsed since the last successful probe — not
 *   since the first failed probe, which only coincides with the last-good time when
 *   probes are frequent and never false-negative; and
 * - at least [MIN_CONSECUTIVE_FAILURES] probes have failed in a row, so a single dropped
 *   probe (packet loss, a momentary Wi-Fi blip) can't trip this on its own.
 *
 * [wentOffline] is a [SharedFlow] with no replay — a collector that starts listening after
 * an episode already fired will not see it retroactively, which is fine for this use case
 * ([AutoHotspotRequestManager] is always already collecting before this starts probing).
 */
class WanReachabilityMonitor(private val scope: CoroutineScope) {
    private val _wentOffline = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val wentOffline: SharedFlow<Unit> = _wentOffline

    @Volatile
    private var lastGoodAtMs: Long = System.currentTimeMillis()

    @Volatile
    private var consecutiveFailures: Int = 0

    /** Whether [wentOffline] has already fired for the *current* offline episode — reset
     *  the moment a probe succeeds again, so the next episode can fire fresh. */
    @Volatile
    private var hasFiredForCurrentEpisode: Boolean = false

    private var started = false

    fun start() {
        if (started) return
        started = true
        scope.launch { runProbeLoop() }
    }

    private suspend fun runProbeLoop() {
        while (true) {
            val reachable = probeOnce()
            val now = System.currentTimeMillis()
            if (reachable) {
                lastGoodAtMs = now
                consecutiveFailures = 0
                hasFiredForCurrentEpisode = false
            } else {
                consecutiveFailures += 1
                val offlineDurationMs = now - lastGoodAtMs
                if (!hasFiredForCurrentEpisode &&
                    consecutiveFailures >= MIN_CONSECUTIVE_FAILURES &&
                    offlineDurationMs >= OFFLINE_THRESHOLD_MS
                ) {
                    hasFiredForCurrentEpisode = true
                    Log.i(TAG, "WAN unreachable for ${offlineDurationMs}ms across $consecutiveFailures probes — firing wentOffline")
                    _wentOffline.tryEmit(Unit)
                }
            }
            delay(PROBE_INTERVAL_MS)
        }
    }

    private suspend fun probeOnce(): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(PROBE_HOST, PROBE_PORT), PROBE_TIMEOUT_MS)
            }
            true
        }.getOrElse {
            Log.d(TAG, "WAN probe failed: ${it.message}")
            false
        }
    }

    companion object {
        const val PROBE_HOST = "1.1.1.1"
        const val PROBE_PORT = 443
        const val PROBE_TIMEOUT_MS = 5_000
        const val PROBE_INTERVAL_MS = 20_000L
        const val OFFLINE_THRESHOLD_MS = 60_000L
        const val MIN_CONSECUTIVE_FAILURES = 3
    }
}
