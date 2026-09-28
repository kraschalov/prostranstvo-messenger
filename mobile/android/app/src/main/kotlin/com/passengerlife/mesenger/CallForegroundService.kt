package com.passengerlife.mesenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat

/**
 * Нативный входящий звонок. Это Foreground Service (категория call), который:
 *  - непрерывно проигрывает рингтон в цикле (MediaPlayer, ringtone.wav)
 *  - вибрирует повторяющимся паттерном
 *  - показывает ongoing-уведомление с fullScreenIntent на CallActivity
 *    (полноэкранный экран звонка поверх блокировки)
 * Главное отличие от flutter_local_notifications: звук не «плюкает» один раз,
 * а звонит непрерывно, и экран открывается сам, без тапа по шторке.
 */
class CallForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "incoming_call_fg"
        const val NOTIFICATION_ID = 1001
        private const val ACTION_RING = "com.passengerlife.mesenger.CALL_RING"
        private const val ACTION_STOP = "com.passengerlife.mesenger.CALL_STOP"
        const val EXTRA_CALLER = "caller"

        @JvmStatic
        fun start(context: Context, caller: String) {
            val i = Intent(context, CallForegroundService::class.java)
                .setAction(ACTION_RING)
                .putExtra(EXTRA_CALLER, caller)
            context.startForegroundService(i)
        }

        @JvmStatic
        fun stop(context: Context) {
            val i = Intent(context, CallForegroundService::class.java).setAction(ACTION_STOP)
            context.startService(i)
        }
    }

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            try {
                stopAll()
            } catch (_: Exception) {
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (action == ACTION_RING) {
            try {
                startRing(intent?.getStringExtra(EXTRA_CALLER) ?: "Входящий звонок")
            } catch (e: Throwable) {
                // Ни при каком исключении не роняем процесс приложения.
                e.printStackTrace()
            }
        }
        return START_NOT_STICKY
    }

    private fun startRing(caller: String) {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Входящий звонок",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Непрерывный рингтон входящего вызова"
                // Звонковый аудио-класс: звучит даже если телефон на беззвучном,
                // если пользователь выставил таковое в настройках канала.
                setSound(null, AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .build())
            }
            notifManager.createNotificationChannel(ch)
        }

        // Полноэкранный интент принудительно открывает КАК РАЗ экран вызова
        // (CallActivity с кнопками Ответить/Отклонить), поверх блокировки.
        val callIntent = Intent(this, CallActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, callIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Входящий звонок")
            .setContentText(caller)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(pending, true)
            .setSmallIcon(R.drawable.ic_stat_call)
            .setContentIntent(pending)
            .build()

        // На Android 14+ (API 34) обязателен тип foreground service; без него
        // startForeground может уронить приложение при входящем звонке.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Непрерывный рингтон.
        try {
            player?.release()
            val p = MediaPlayer.create(this, R.raw.ringtone)
            p?.isLooping = true
            p?.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            p?.start()
            player = p
        } catch (_: Exception) {
        }

        // Повторяющаяся вибрация.
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
            val pattern = longArrayOf(0, 600, 400, 600, 400)
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
        stopForeground(true)
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
}