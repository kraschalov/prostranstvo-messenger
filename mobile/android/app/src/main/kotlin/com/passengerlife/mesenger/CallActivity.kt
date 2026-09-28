package com.passengerlife.mesenger

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * Полноэкранная Activity входящего звонка. Показывается поверх блокировки
 * и пробуждает экран — как у обычных телефонных звонков.
 */
class CallActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // ПРОБИВКА БЛОКИРОВКИ: включаем экран и показываем поверх ДО создания
        // вида, чтобы звонок «вылетал» на весь экран, а не прятался в шторке.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                    or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onCreate(savedInstanceState)
        try {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (km.isKeyguardLocked) {
                @Suppress("DEPRECATION")
                km.requestDismissKeyguard(this, null)
            }
        } catch (_: Exception) {
        }
    }
}
