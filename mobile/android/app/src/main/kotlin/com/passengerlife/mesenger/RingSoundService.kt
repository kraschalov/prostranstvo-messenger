package com.passengerlife.mesenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Непрерывный рингтон входящего звонка. Это foreground-сервис (категория call),
 * который играет ringtone.wav в цикле через MediaPlayer.isLooping=true и вибрирует.
 *
 * ЭКРАН звонка (полноэкранный, поверх блокировки) показывает flutter_callkit_incoming —
 * этот сервис отвечает ТОЛЬКО за длинный непрерывный звук, потому что колкит играет
 * свой рингон через Ringtone, а на некоторых прошивках (HyperOS/MIUI) Ringtone
 * зацикливание игнорирует и звучит один раз («пик»).
 */
class RingSoundService : Service() {

    companion object {
        const val CHANNEL_ID = "incoming_ring_fg"
        const val NOTIFICATION_ID = 1002
        private const val ACTION_RING = "com.passengerlife.mesenger.RING_SOUND"
        private const val ACTION_STOP = "com.passengerlife.mesenger.STOP_RING_SOUND"
        const val EXTRA_CALLER = "caller"

        @JvmStatic
        fun start(context: Context, caller: String, ringtone: String) {
            val i = Intent(context, RingSoundService::class.java)
                .setAction(ACTION_RING)
                .putExtra(EXTRA_CALLER, caller)
                .putExtra(EXTRA_RINGTONE, ringtone)
            ContextCompat.startForegroundService(context, i)
        }

        @JvmStatic
        fun stop(context: Context) {
            val i = Intent(context, RingSoundService::class.java).setAction(ACTION_STOP)
            context.startService(i)
        }

        const val EXTRA_RINGTONE = "ringtone"
    }

private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var audioFocus: AudioManager? = null

    private fun am(): AudioManager? {
        if (audioFocus == null) {
            audioFocus = getSystemService(Context.AUDIO_SERVICE) as AudioManager?
        }
        return audioFocus
    }

    // Системный Telecom/звонок на новом Android (HyperOS) может отобрать
    // аудио-фокус и «задушить» наш рингтон за ~0.5с. При потере фокуса
    // запрашиваем его снова и перезапускаем плеер — рингтон продолжит.
    private val audioFocusChange: AudioManager.OnAudioFocusChangeListener =
        AudioManager.OnAudioFocusChangeListener { change ->
            try {
                if (change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
                ) {
                    val mgr = am()
                    mgr?.requestAudioFocus(
                        this@RingSoundService.audioFocusChange,
                        AudioManager.STREAM_RING,
                        AudioManager.AUDIOFOCUS_GAIN,
                    )
                }
                val p = player
                if (p != null && !p.isPlaying) {
                    p.start()
                }
            } catch (_: Exception) {
            }
        }

    // Глушит рингтон при нажатии кнопки громкости (как в обычном телефоне).
    // Звонок при этом НЕ сбрасывается — звук продолжит молчать до ответа/сброса.
    private var volumeKeyReceiver: BroadcastReceiver? = null
    private var ringStartedAt: Long = 0L

    private val volumeKeyReceiverAction = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "android.media.VOLUME_CHANGED_ACTION") {
                // На новом Android (HyperOS) при входящем системный звонок сам
                // меняет громкость → VOLUME_CHANGED_ACTION приходит сразу и
                // заглушал рингон за ~0.5с. Игнорируем смены громкости в первые
                // 1.5 секунды после старта звонка — это не нажатие кнопки.
                if (System.currentTimeMillis() - ringStartedAt < 1500) {
                    return
                }
                muteRing()
            }
        }
    }

    private fun registerVolumeReceiver() {
        try {
            volumeMuteRegistered = true
            ContextCompat.registerReceiver(
                this,
                volumeKeyReceiverAction,
                IntentFilter("android.media.VOLUME_CHANGED_ACTION"),
                ContextCompat.RECEIVER_EXPORTED,
            )
        } catch (_: Exception) {
        }
    }

    private fun unregisterVolumeReceiver() {
        try {
            if (volumeMuteRegistered) {
                unregisterReceiver(volumeKeyReceiverAction)
            }
            volumeMuteRegistered = false
        } catch (_: Exception) {
        }
    }

    private var volumeMuteRegistered = false

    /// Ставит рингтон на паузу (и глушит вибро), не трогая звонок.
    private fun muteRing() {
        try {
            player?.pause()
        } catch (_: Exception) {
        }
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            try {
                stopAll()
            } catch (_: Exception) {
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_RING) {
            try {
                startRing(
                    intent.getStringExtra(EXTRA_CALLER) ?: "Входящий звонок",
                    intent.getStringExtra(EXTRA_RINGTONE) ?: "ringtone"
                )
            } catch (e: Throwable) {
                e.printStackTrace()
            }
        }
        return START_NOT_STICKY
    }

    private fun startRing(caller: String, ringtoneName: String) {
        ringStartedAt = System.currentTimeMillis()
        registerVolumeReceiver()
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Рингтон звонка",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Непрерывный звук входящего вызова"
                setSound(null, null)
            }
            notifManager.createNotificationChannel(ch)
        }

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Входящий звонок")
            .setContentText(caller)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSilent(true)
            // ВАЖНО: НЕ android.R.drawable.ic_menu_call — системная иконка на
            // HyperOS/MIUI даёт RemoteServiceException «Bad notification for
            // startForeground» и роняет приложение при входящем звонке/ответе.
            .setSmallIcon(R.drawable.ic_stat_call)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // Ошибка startForeground не должна ронять процесс приложения.
        }

        // Непрерывный рингтон в цикле. Ищем выбранный raw-ресурс по имени
        // (ringtone, ring1..ring8); при неудаче подстраховка — ringtone.wav.
        try {
            player?.release()
            var resId = resources.getIdentifier(ringtoneName, "raw", packageName)
            if (resId == 0) resId = R.raw.ringtone
            val p = MediaPlayer.create(this, resId)
            p?.isLooping = true
            p?.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            p?.start()
            player = p
            // Занимаем аудио-фокус на звонок, чтобы системный Telecom/HyperOS
            // не отобрал его и не оборвал рингтон через полсекунды.
            try {
                am()?.requestAudioFocus(
                    audioFocusChange,
                    AudioManager.STREAM_RING,
                    AudioManager.AUDIOFOCUS_GAIN,
                )
            } catch (_: Exception) {
            }
        } catch (_: Exception) {
        }

        // Вибрация.
        try {
            @Suppress("DEPRECATION")
            val vib: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(Context.VIBRATOR_MANAGER_SERVICE)?.let {
                    (it as VibratorManager).defaultVibrator
                }
            } else {
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator?
            }
            vibrator = vib
            val pattern = longArrayOf(0, 1000, 1000)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vib?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vib?.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopAll() {
        unregisterVolumeReceiver()
        try {
            am()?.abandonAudioFocus(audioFocusChange)
        } catch (_: Exception) {
        }
        try {
            player?.stop()
        } catch (_: Exception) {
        }
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
        try {
            stopForeground(true)
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
}