package dev.vmd1.gossip.crypto

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/**
 * This device's stable identity: a UUID generated once at first launch plus a
 * long-term Ed25519 signing keypair and X25519 Noise static keypair, persisted so
 * they survive app restarts. Values live in an [EncryptedSharedPreferences] file
 * backed by the Android Keystore master key — Keystore's own asymmetric-key API
 * does not cleanly expose raw X25519 scalars for use inside a hand-rolled Noise
 * session, so the keys themselves are generated with BouncyCastle and the *file
 * they live in* is what Keystore protects.
 */
class IdentityKeyStore private constructor(private val prefs: SharedPreferences) {

    val deviceId: String by lazy {
        prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }
    }

    val x25519KeyPair: X25519KeyPair by lazy { loadOrCreateX25519() }

    val ed25519PrivateKey: ByteArray by lazy { loadOrCreateEd25519() }

    /** Random key shared with trusted peers so they can recognise this device's BLE advertisements (see `BeaconTag`). */
    val beaconKey: ByteArray by lazy { loadOrCreateBeaconKey() }

    val ed25519PublicKey: ByteArray by lazy {
        Ed25519PrivateKeyParameters(ed25519PrivateKey, 0).generatePublicKey().encoded
    }

    /** Short fingerprint of the X25519 static public key, e.g. for QR payloads / NSD TXT records. */
    fun publicKeyFingerprint(): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(x25519KeyPair.publicKey)
        return Base64.encodeToString(digest, Base64.NO_WRAP or Base64.NO_PADDING).take(16)
    }

    private fun loadOrCreateX25519(): X25519KeyPair {
        val storedPriv = prefs.getString(KEY_X25519_PRIVATE, null)
        val storedPub = prefs.getString(KEY_X25519_PUBLIC, null)
        if (storedPriv != null && storedPub != null) {
            return X25519KeyPair(decode(storedPriv), decode(storedPub))
        }
        val generated = X25519Utils.generateKeyPair()
        prefs.edit()
            .putString(KEY_X25519_PRIVATE, encode(generated.privateKey))
            .putString(KEY_X25519_PUBLIC, encode(generated.publicKey))
            .apply()
        return generated
    }

    private fun loadOrCreateEd25519(): ByteArray {
        val stored = prefs.getString(KEY_ED25519_PRIVATE, null)
        if (stored != null) return decode(stored)
        val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(KEY_ED25519_PRIVATE, encode(seed)).apply()
        return seed
    }

    private fun loadOrCreateBeaconKey(): ByteArray {
        val stored = prefs.getString(KEY_BEACON, null)
        if (stored != null) return decode(stored)
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(KEY_BEACON, encode(key)).apply()
        return key
    }

    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)

    companion object {
        private const val PREFS_FILE = "connect_identity_keystore"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_X25519_PRIVATE = "x25519_private"
        private const val KEY_X25519_PUBLIC = "x25519_public"
        private const val KEY_ED25519_PRIVATE = "ed25519_private"
        private const val KEY_BEACON = "ble_beacon_key"

        @Volatile
        private var instance: IdentityKeyStore? = null

        fun getInstance(context: Context): IdentityKeyStore =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        /** Ensures identity material exists, generating it on first launch. Safe to call repeatedly. */
        fun ensureInitialized(context: Context) {
            getInstance(context).apply {
                // Touch the lazily-created values so they're generated & persisted immediately.
                deviceId
                x25519KeyPair
                ed25519PrivateKey
            }
        }

        private fun build(context: Context): IdentityKeyStore {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                context,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            return IdentityKeyStore(prefs)
        }
    }
}
