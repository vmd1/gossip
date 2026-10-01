package dev.vmd1.gossip.features.screenmirror

import rikka.shizuku.Shizuku

/**
 * Runs a command at shell UID via Shizuku's binder-IPC `newProcess`. Shizuku's 13.x API made
 * `Shizuku.newProcess` private (the supported replacement is a bound `UserService`, which is
 * overkill for "exec one command and stream its stdio"), so this reflects into it — the same
 * thing every `newProcess` consumer does since the 13.0 change. The returned object is a
 * `rikka.shizuku.ShizukuRemoteProcess`, a normal `java.lang.Process` whose stdio is piped
 * over binder from the shell-UID side.
 */
internal object ShizukuShell {
    private val newProcessMethod by lazy {
        Shizuku::class.java.getDeclaredMethod(
            "newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java
        ).apply { isAccessible = true }
    }

    fun exec(vararg command: String): Process =
        newProcessMethod.invoke(null, arrayOf(*command), null, null) as Process
}
