package dev.vmd1.gossip.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import dev.vmd1.gossip.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

private const val TAG = "NsdDiscovery"
const val GOSSIP_SERVICE_TYPE = "_gossip._tcp."
private const val MAX_RESOLVE_ATTEMPTS = 5
private const val RESOLVE_RETRY_DELAY_MS = 500L

/** A peer discovered (or lost) on the local network via mDNS/NSD. */
data class DiscoveredPeer(
    val serviceName: String,
    val host: String?,
    val port: Int,
    val deviceId: String?,
    val publicKeyFingerprint: String?
)

sealed class DiscoveryEvent {
    data class Found(val peer: DiscoveredPeer) : DiscoveryEvent()
    data class Lost(val serviceName: String) : DiscoveryEvent()
}

/**
 * Registers this device on the local network under `_gossip._tcp` (TXT record carrying
 * `deviceId` + the X25519 public-key fingerprint, matching what the Mac's Bonjour
 * advertisement provides) and discovers peers advertising the same service type.
 */
class NsdDiscovery(context: Context, private val deviceId: String, private val publicKeyFingerprint: String) {

    private val nsdManager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registrationListener: NsdManager.RegistrationListener? = null

    /** Advertises this device's sync service (call once the server socket is listening on [port]). */
    fun startAdvertising(deviceName: String, port: Int) {
        stopAdvertising()
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "connect-$deviceId"
            serviceType = GOSSIP_SERVICE_TYPE
            setPort(port)
            setAttribute("deviceId", deviceId)
            setAttribute("fp", publicKeyFingerprint)
            setAttribute("name", deviceName)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD service registered: ${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed ($errorCode) for ${info.serviceName}")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD service unregistered: ${info.serviceName}")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed ($errorCode)")
            }
        }
        registrationListener = listener
        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopAdvertising() {
        registrationListener?.let {
            runCatching { nsdManager.unregisterService(it) }
        }
        registrationListener = null
    }

    /** A cold flow of discovery events; discovery runs while the flow is collected. */
    fun discover(): Flow<DiscoveryEvent> = callbackFlow {
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.i(TAG, "Discovery started for $regType")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                // Never look up this device's own advertisement.
                if (service.serviceName == "connect-$deviceId") return
                enqueueResolve(service)
            }

            private val resolveQueue = ArrayDeque<Pair<NsdServiceInfo, Int>>()
            private var resolving = false

            /** Android's NsdManager (before API 34) allows only **one** `resolveService` at a time and
             *  fails any concurrent call with FAILURE_ALREADY_ACTIVE (3) — so when several services show
             *  up together (e.g. a Mac and another Android device) all but one lookup used to fail and
             *  were never retried, leaving that peer undiscoverable. Lookups are queued and run one at a
             *  time, and an "already active" failure (some other lookup in flight) is retried. */
            @Synchronized
            private fun enqueueResolve(service: NsdServiceInfo, attempt: Int = 0) {
                resolveQueue.addLast(service to attempt)
                drainResolveQueue()
            }

            @Synchronized
            private fun drainResolveQueue() {
                if (resolving) return
                val (service, attempt) = resolveQueue.removeFirstOrNull() ?: return
                resolving = true
                nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        Log.w(TAG, "Resolve failed for ${info.serviceName}: $errorCode (attempt ${attempt + 1})")
                        finishResolve()
                        if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE && attempt < MAX_RESOLVE_ATTEMPTS) {
                            launch {
                                delay(RESOLVE_RETRY_DELAY_MS)
                                enqueueResolve(service, attempt + 1)
                            }
                        }
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        finishResolve()
                        val attrs = info.attributes
                        val peer = DiscoveredPeer(
                            serviceName = info.serviceName,
                            host = info.host?.hostAddress,
                            port = info.port,
                            deviceId = attrs["deviceId"]?.let { String(it, Charsets.UTF_8) },
                            publicKeyFingerprint = attrs["fp"]?.let { String(it, Charsets.UTF_8) }
                        )
                        trySend(DiscoveryEvent.Found(peer))
                    }
                })
            }

            @Synchronized
            private fun finishResolve() {
                resolving = false
                drainResolveQueue()
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                trySend(DiscoveryEvent.Lost(service.serviceName))
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "Discovery stopped for $serviceType")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Start discovery failed ($errorCode)")
                close()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Stop discovery failed ($errorCode)")
            }
        }

        nsdManager.discoverServices(GOSSIP_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)

        awaitClose {
            runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        }
    }
}
