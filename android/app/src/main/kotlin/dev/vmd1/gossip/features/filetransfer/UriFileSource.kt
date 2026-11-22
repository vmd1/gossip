package dev.vmd1.gossip.features.filetransfer

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.FileInputStream
import java.io.InputStream
import java.nio.ByteBuffer

/** A file picked through the share sheet or a document picker, read at arbitrary offsets so a resumed send can start mid-file. */
class UriFileSource(private val resolver: ContentResolver, private val uri: Uri) : FileSource {
    override val name: String
    override val size: Long

    init {
        var n = "file"
        var s = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getString(0)?.let { n = it }
                if (!c.isNull(1)) s = c.getLong(1)
            }
        }
        name = n
        size = if (s >= 0) s else resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
    }

    private val pfd: ParcelFileDescriptor by lazy { resolver.openFileDescriptor(uri, "r") ?: error("Cannot open $uri") }

    override fun open(): InputStream = resolver.openInputStream(uri) ?: error("Cannot open $uri")

    override fun read(offset: Long, length: Int): ByteArray {
        val channel = FileInputStream(pfd.fileDescriptor).channel
        val buffer = ByteBuffer.allocate(length)
        var position = offset
        while (buffer.hasRemaining()) {
            val n = channel.read(buffer, position)
            if (n < 0) break
            position += n
        }
        return buffer.array().copyOf(buffer.position())
    }
}
