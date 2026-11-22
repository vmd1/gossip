package dev.vmd1.gossip.features.filetransfer

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import dev.vmd1.gossip.crypto.TrustedDevicesStore
import dev.vmd1.gossip.transport.TransportManagerHolder

/** The share-sheet target: "Gossip" in Share → pick one of your connected devices → the files are offered to it. */
class ShareToDeviceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = sharedUris(intent)
        val send = FileTransferHolder.sendUri
        val transport = TransportManagerHolder.instance
        if (uris.isEmpty() || send == null || transport == null) {
            Toast.makeText(this, "Gossip is not running. Open the app and try again.", Toast.LENGTH_LONG).show()
            finish(); return
        }
        val connected = transport.connectedDeviceIds.value
        val devices = TrustedDevicesStore.getInstance(applicationContext).allDevices().filter { it.deviceId in connected }
        if (devices.isEmpty()) {
            Toast.makeText(this, "No connected device to send to.", Toast.LENGTH_LONG).show()
            finish(); return
        }
        AlertDialog.Builder(this)
            .setTitle(if (uris.size == 1) "Send to" else "Send ${uris.size} files to")
            .setItems(devices.map { it.deviceName }.toTypedArray()) { _, which ->
                uris.forEach { send(devices[which].deviceId, it) }
                Toast.makeText(this, "Offered to ${devices[which].deviceName}", Toast.LENGTH_SHORT).show()
                finish()
            }
            .setOnCancelListener { finish() }
            .show()
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else -> emptyList()
    }
}
