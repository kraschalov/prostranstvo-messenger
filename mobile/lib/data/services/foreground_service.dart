import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mesenger/core/calls/call_log.dart';

/// Постоянный фоновый сервис: держит процесс и main-изолят живыми, чтобы
/// WebSocket, уведомления и входящие звонки (callkit) работали даже при
/// свёрнутом приложении. Это «как у Telegram»: пока приложение установлено
/// и не выгружено системой, доставка идёт.
class ForegroundService {
  ForegroundService._();

  static final ForegroundService instance = ForegroundService._();

  static const _channelId = 'mesenger_foreground';
  static const _channelName = 'Пространство активно';
  static const _title = 'Пространство';
  static const _text = 'Работает в фоне: сообщения и звонки доходят сразу';

  /// Инициализация один раз при старте приложения.
  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: _text,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
      ),
    );
  }

  /// Запустить фоновый сервис (после входа в аккаунт / восстановления сессии).
  Future<void> start() async {
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (running) return;
      final result = await FlutterForegroundTask.startService(
        serviceTypes: const [
          ForegroundServiceTypes.dataSync,
          ForegroundServiceTypes.remoteMessaging,
        ],
        notificationTitle: _title,
        notificationText: _text,
        callback: null,
      );
      await CallLog.instance.write('FG start result=$result');
    } catch (e) {
      await CallLog.instance.write('FG start FAIL: $e');
    }
  }

  /// Остановить фоновый сервис (при выходе из аккаунта).
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
      await CallLog.instance.write('FG stop');
    } catch (e) {
      await CallLog.instance.write('FG stop FAIL: $e');
    }
  }
}
