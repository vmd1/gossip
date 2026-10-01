package dev.vmd1.gossip.features.find

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.util.Log

/** Loops the default alarm sound on the alarm stream (audible even when the ringer is on silent/
 *  vibrate), temporarily raising the alarm volume to max and restoring it afterwards. */
class AlarmRinger(private val context: Context) : Ringer {
    private var player: MediaPlayer? = null
    private var savedVolume: Int? = null

    @Synchronized
    override fun start() {
        if (player != null) return
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        runCatching {
            savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
            audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(context, uri)
                isLooping = true
                prepare()
                start()
            }
        }.onFailure { Log.w(TAG, "Failed to start ring", it); stop() }
    }

    @Synchronized
    override fun stop() {
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
        savedVolume?.let { v ->
            runCatching {
                (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).setStreamVolume(AudioManager.STREAM_ALARM, v, 0)
            }
        }
        savedVolume = null
    }

    private companion object { const val TAG = "AlarmRinger" }
}
