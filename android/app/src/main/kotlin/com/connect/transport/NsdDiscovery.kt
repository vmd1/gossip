package com.connect.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

private const val TAG = "NsdDiscovery"
const val CONNECT_SERVICE_TYPE = "_connect._tcp."

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
 * Registers this device on the local network under `_connect._tcp` (TXT record carrying
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
            serviceType = CONNECT_SERVICE_TYPE
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
                nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        Log.w(TAG, "Resolve failed for ${info.serviceName}: $errorCode")
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
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

        nsdManager.discoverServices(CONNECT_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)

        awaitClose {
            runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
        }
    }
}
