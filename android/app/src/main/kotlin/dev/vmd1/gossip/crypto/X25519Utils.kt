package dev.vmd1.gossip.crypto

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom

/** A raw 32-byte X25519 keypair, used both for the device's stable Noise static key
 *  and for ephemeral keys generated during each handshake. */
data class X25519KeyPair(val privateKey: ByteArray, val publicKey: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is X25519KeyPair) return false
        return privateKey.contentEquals(other.privateKey) && publicKey.contentEquals(other.publicKey)
    }

    override fun hashCode(): Int = privateKey.contentHashCode() * 31 + publicKey.contentHashCode()
}

object X25519Utils {
    private val secureRandom = SecureRandom()

    fun generateKeyPair(): X25519KeyPair {
        val priv = X25519PrivateKeyParameters(secureRandom)
        val pub = priv.generatePublicKey()
        return X25519KeyPair(priv.encoded, pub.encoded)
    }

    /** Diffie-Hellman agreement between a local private key and a remote public key. */
    fun dh(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        val priv = X25519PrivateKeyParameters(privateKey, 0)
        val pub = X25519PublicKeyParameters(publicKey, 0)
        val agreement = X25519Agreement()
        agreement.init(priv)
        val out = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(pub, out, 0)
        return out
    }
}
