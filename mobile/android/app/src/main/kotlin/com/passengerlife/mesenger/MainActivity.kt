package com.passengerlife.mesenger

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mesenger/incoming_ring"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRing" -> {
                    val caller = call.argument<String>("caller") ?: "Входящий звонок"
                    val ringtone = call.argument<String>("ringtone") ?: "ringtone"
                    RingSoundService.start(applicationContext, caller, ringtone)
                    result.success(true)
                }
                "stopRing" -> {
                    RingSoundService.stop(applicationContext)
                    result.success(true)
                }
                "setSpeaker" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    setSpeaker(enable)
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(installApk(path))
                }
                "installPermission" -> {
                    val granted = packageManager.canRequestPackageInstalls()
                    result.success(granted)
                }
                "apkSignerSha256" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(apkSignerSha256(path))
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mesenger/deep_link"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitial" -> {
                    result.success(intent?.data?.toString())
                }
                else -> result.notImplemented()
            }
        }
    }

    /// SHA-256 отпечатка сертификата подписи APK (сверить с релизным
    /// ключом до установки — защита от подмены в пути). Пустой ответ =
    /// прочитать не удалось (считать файл недоверенным).
    private fun apkSignerSha256(apkPath: String): String {
        return try {
            val pm = packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageArchiveInfo(
                    apkPath,
                    android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageArchiveInfo(
                    apkPath,
                    android.content.pm.PackageManager.GET_SIGNATURES
                )
            } ?: return ""
            val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signing = info.signingInfo ?: return ""
                if (signing.hasMultipleSigners()) signing.apkContentsSigners
                else signing.signingCertificateHistory
            } else {
                @Suppress("DEPRECATION")
                info.signatures
            } ?: return ""
            if (sigs.isEmpty()) return ""
            val md = java.security.MessageDigest.getInstance("SHA-256")
            val digest = md.digest(sigs[0].toByteArray())
            digest.joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            ""
        }
    }

    /// Запуск установки скачанного APK через системный установщик.
    /// На Android 8+ требуется разрешение «Установка из этого источника»:
    /// возвращает "no_permission" (настройки открыты) | "ok" | "file_missing".
    private fun installApk(apkPath: String): String {
        // Android 8+ (API 26+): проверяем разрешение на установку из
        // неизвестных источников для нашего приложения.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!packageManager.canRequestPackageInstalls()) {
                try {
                    val settingsIntent = Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(settingsIntent)
                } catch (e: Exception) {
                    return "settings_launch_failed"
                }
                return "no_permission"
            }
        }
        return try {
            val file = File(apkPath)
            if (!file.exists()) {
                android.util.Log.e("MesengerInstall", "APK not exists: $apkPath")
                return "file_missing"
            }
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            android.util.Log.i("MesengerInstall", "uri=$uri actualFile=${file.absolutePath}")
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            "ok"
        } catch (e: Exception) {
            android.util.Log.e("MesengerInstall", "install trigger fail: $apkPath", e)
            "launch_failed"
        }
    }

    /// Нативное переключение трубка/громкая связь.
    /// На Android 12+ (HyperOS/POCO) плагиновый selectAudioOutput игнорируется
    /// для звонкового аудио — используем AudioManager.setCommunicationDevice
    /// (официальный API для коммуникационных устройств). На старых версиях —
    /// isSpeakerphoneOn.
    ///
    /// Важно: на Hyper Audio во время активного WebRTC-звонка
    /// (audio mode = inCommunication) в availableCommunicationDevices может
    /// не быть TYPE_BUILTIN_SPEAKER — тогда setCommunicationDevice молча
    /// не роутит. Fallback на isSpeakerphoneOn=true срабатывает НА ЛЮБОЙ
    /// версии Android (депрекатед, но работает), чтобы списокер гарантированно
    /// включался на обоих телефонах (old Redmi + new POCO/Hyper).
    private fun setSpeaker(enable: Boolean) {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            // Режим COMMUNICATION нужен, чтобы Hyper/OS опознал звонковое аудио
            // и маршрутизация (setCommunicationDevice/isSpeakerphoneOn) влияла
            // на активный WebRTC-поток.
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (enable) {
                // Двойной форс: и официальный communication-device, и классика.
                // На одном из путей должен сработать (Redmi: isSpeakerphoneOn;
                // POCO/Hyper: setCommunicationDevice, если спикер в списке).
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                    val speaker = am.availableCommunicationDevices
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    if (speaker != null) {
                        am.setCommunicationDevice(speaker)
                    }
                }
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                    val earpiece = am.availableCommunicationDevices
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                    if (earpiece != null) {
                        am.setCommunicationDevice(earpiece)
                    }
                }
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = false
            }
        } catch (_: Exception) {
        }
    }
}