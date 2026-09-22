package com.connect.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.connect.R
import com.connect.crypto.IdentityKeyStore
import com.connect.crypto.TrustedDevicesStore
import com.connect.transport.MessageRouter
import com.connect.transport.TransportManager
import com.connect.transport.TransportManagerHolder

/**
 * Foreground service that owns the [TransportManager] for the lifetime of the app,
 * so the device keeps listening/reconnecting to its paired Mac even while no UI is
 * visible. Runs with a persistent low-priority "Connect is running" notification, as
 * required for a `dataSync`-typed foreground service.
 */
class SyncForegroundService : Service() {

    private lateinit var transportManager: TransportManager

    override fun onCreate() {
        super.onCreate()
        IdentityKeyStore.ensureInitialized(applicationContext)
        val identity = IdentityKeyStore.getInstance(applicationContext)
        val trustedDevices = TrustedDevicesStore.getInstance(applicationContext)
        transportManager = TransportManager(
            context = applicationContext,
            identityKeyStore = identity,
            trustedDevicesStore = trustedDevices,
            messageRouter = MessageRouter()
        )
        TransportManagerHolder.instance = transportManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        transportManager.listen()
        return START_STICKY
    }

    override fun onDestroy() {
        transportManager.shutdown()
        if (TransportManagerHolder.instance === transportManager) {
            TransportManagerHolder.instance = null
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun transportManager(): TransportManager = transportManager

    inner class LocalBinder : android.os.Binder() {
        fun service(): SyncForegroundService = this@SyncForegroundService
    }

    private val binder = LocalBinder()

    private fun buildNotification(): Notification {
        val channelId = ensureChannel()
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(getString(R.string.sync_notification_title))
            .setContentText(getString(R.string.sync_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.sync_notification_channel),
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }
        return CHANNEL_ID
    }

    companion object {
        private const val CHANNEL_ID = "connect_sync"
        private const val NOTIFICATION_ID = 1001
    }
}
