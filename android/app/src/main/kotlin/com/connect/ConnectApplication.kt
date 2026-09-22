package com.connect

import android.app.Application
import com.connect.crypto.IdentityKeyStore

/** Application entry point: makes sure this device's stable identity (UUID + Ed25519 /
 *  X25519 keypairs) exists before anything else runs. */
class ConnectApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        IdentityKeyStore.ensureInitialized(this)
    }
}
