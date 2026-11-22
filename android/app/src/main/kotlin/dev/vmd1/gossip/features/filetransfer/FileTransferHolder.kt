package dev.vmd1.gossip.features.filetransfer

import android.net.Uri

/** The running [FileTransferManager] and the "send this Uri" entry point, for the share sheet and the UI (same idea as
 *  `TransportManagerHolder`): set by the foreground service while it runs. */
object FileTransferHolder {
    @Volatile var manager: FileTransferManager? = null
    @Volatile var sendUri: ((peerId: String, uri: Uri) -> Unit)? = null
}
