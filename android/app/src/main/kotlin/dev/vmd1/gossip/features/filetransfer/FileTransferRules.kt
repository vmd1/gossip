package dev.vmd1.gossip.features.filetransfer

/** The pure rules of file transfer (`docs/plans/file-transfer.md`), pinned by `schema/file-transfer-cases.json` and
 *  mirrored by the Mac app. */
object FileTransferRules {
    const val CHUNK_SIZE = 1_048_576
    const val MAX_FILE_BYTES = 2L * 1024 * 1024 * 1024
    const val MAX_INCOMING = 3
    const val MAX_NAME_LENGTH = 120

    /** A name from the wire reduced to a safe single path component. Never empty, never contains a separator. */
    fun sanitizeName(raw: String): String {
        val last = raw.substringAfterLast('/').substringAfterLast('\\')
        val cleaned = last.filter { !it.isISOControl() }.trim().trimStart('.').trimEnd('.', ' ').trim()
        if (cleaned.isEmpty()) return "file"
        if (cleaned.length <= MAX_NAME_LENGTH) return cleaned
        val dot = cleaned.lastIndexOf('.')
        val ext = if (dot > 0 && cleaned.length - dot <= 16) cleaned.substring(dot) else ""
        return cleaned.substring(0, MAX_NAME_LENGTH - ext.length) + ext
    }

    /** [name], or `name (2).ext`, `name (3).ext`, ... until [isTaken] says the name is free. */
    fun uniqueName(name: String, isTaken: (String) -> Boolean): String {
        if (!isTaken(name)) return name
        val dot = name.lastIndexOf('.')
        val (stem, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        var n = 2
        while (true) {
            val candidate = "$stem ($n)$ext"
            if (!isTaken(candidate)) return candidate
            n++
        }
    }

    fun chunkCount(size: Long, chunkSize: Int = CHUNK_SIZE): Int = ((size + chunkSize - 1) / chunkSize).toInt()

    fun chunkLength(size: Long, chunkSize: Int, index: Int): Int {
        val start = index.toLong() * chunkSize
        return (size - start).coerceIn(0, chunkSize.toLong()).toInt()
    }

    /** The first chunk index not yet received: what a receiver asks the sender to resume from. */
    fun nextIndex(received: Set<Int>): Int {
        var i = 0
        while (i in received) i++
        return i
    }
}
