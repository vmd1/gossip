package dev.vmd1.gossip.features.clipboard

import java.io.File

/** What clipboard content is allowed to leave or enter this device, kept pure so it can be unit tested. */
object ClipboardPolicy {
    const val MAX_TEXT_BYTES = 1 shl 20          // 1 MiB
    const val MAX_IMAGE_BYTES = 8 shl 20         // 8 MiB of PNG
    const val MAX_IMAGE_PIXELS = 40_000_000L     // a decompression-bomb guard: decoded size, not file size

    /** Set by apps that copy secrets (password managers); [android.content.ClipDescription.EXTRA_IS_SENSITIVE] on API 33+. */
    const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"

    fun textAllowed(text: String): Boolean = text.length <= MAX_TEXT_BYTES && text.toByteArray(Charsets.UTF_8).size <= MAX_TEXT_BYTES

    fun imageBytesAllowed(size: Int): Boolean = size in 1..MAX_IMAGE_BYTES

    fun imageDimensionsAllowed(width: Int, height: Int): Boolean =
        width > 0 && height > 0 && width.toLong() * height.toLong() <= MAX_IMAGE_PIXELS

    fun isSensitive(extras: android.os.PersistableBundle?): Boolean = extras?.getBoolean(EXTRA_IS_SENSITIVE, false) == true

    /** Deletes every file in [dir] except [keep] — received clipboard images are only needed while they're on the clipboard. */
    fun pruneCache(dir: File, keep: File? = null) {
        dir.listFiles()?.forEach { if (it != keep) runCatching { it.delete() } }
    }
}
