import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Локальные уведомления: звук для сообщения и полноэкранные уведомления
/// о входящем звонке.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _fullScreenGranted = false;

  Future<void> init() async {
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidInit);
      final ok = await _plugin.initialize(settings);
      _ready = true;
      // Явно создаём канал звонков (важно: канал со звуком создаётся один
      // раз; при обновлении приложения с новым рингтоном его надо
      // пересоздать, иначе звук останется прежним).
      await _createCallChannel();
      // На Android 14+ полноэкранные уведомления требуют особого разрешения.
      await requestFullScreenPermission();
      debugPrint('NOTIF READY: $ok, fullScreen=$_fullScreenGranted');
    } catch (e) {
      _ready = false;
      debugPrint('NOTIF INIT FAIL: $e');
    }
  }

  Future<void> _createCallChannel() async {
    try {
      final impl = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      // Звук канала нельзя изменить после первого создания. При апдейте
      // приложения канал 'calls' уже существует со старым/дефолтным звуком —
      // поэтому СНАЧАЛА удаляем старый канал, затем создаём заново с нашим
      // рингтоном. Иначе звонок «плюхает» как обычное сообщение.
      try {
        await impl?.deleteNotificationChannel('calls');
      } catch (_) {}
      const channel = AndroidNotificationChannel(
        'calls',
        'Звонки',
        description: 'Входящие звонки',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('ringtone'),
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      );
      await impl?.createNotificationChannel(channel);
    } catch (e) {
      debugPrint('NOTIF CHANNEL FAIL: $e');
    }
  }

  /// Удаляет каналы уведомлений, которые создаёт flutter_callkit_incoming.
  /// Android фиксирует звук канала при его ПЕРВОМ создании и не меняет его
  /// при повторном showCallkitIncoming. Если канал callkit уже существовал
  /// (например, создан в прошлой версии со старым/дефолтным звуком), звонок
  /// «плюхает» как обычное сообщение — один «пик». Удаление канала перед
  /// показом заставляет колкит пересоздать его заново с нашим рингтоном.
  static const _callkitChannels = <String>[
    'callkit_incoming_channel_id_v2',
    'callkit_incoming_channel_id',
    'callkit_ongoing_channel_id',
    'callkit_missed_channel_id',
  ];

  Future<void> deleteCallkitChannels() async {
    try {
      final impl = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      for (final id in _callkitChannels) {
        try {
          await impl?.deleteNotificationChannel(id);
        } catch (_) {}
      }
      debugPrint('NOTIF CALLKIT CHANNELS DELETED');
    } catch (e) {
      debugPrint('NOTIF CALLKIT CHANNEL DEL FAIL: $e');
    }
  }

  Future<void> requestFullScreenPermission() async {
    try {
      final res = await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestFullScreenIntentPermission();
      _fullScreenGranted = res == true;
      debugPrint('FSI REQUESTED -> $_fullScreenGranted');
    } catch (e) {
      debugPrint('FSI REQUEST FAIL: $e');
    }
  }

  Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Сообщения',
          channelDescription: 'Уведомления о новых сообщениях',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
      );
      final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _plugin.show(id, title, body, details);
    } catch (e) {
      debugPrint('NOTIF SHOW FAIL: $e');
    }
  }

  /// Полноэкранное уведомление о входящем звонке: будит экран, звучит
  /// зацикленно одним блоком (ringtone), не смахивается (ongoing) и открывает
  /// приложение даже со свёрнутого/заблокированного экрана.
  Future<void> showIncomingCall({
    required String caller,
    required String callId,
  }) async {
    if (!_ready) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Звонки',
          channelDescription: 'Входящие звонки',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          ongoing: true,
          autoCancel: false,
          sound: RawResourceAndroidNotificationSound('ringtone'),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          vibrationPattern: Int64List.fromList(
            [400, 400, 400, 400, 400, 400],
          ),
        ),
      );
      final id = callId.hashCode & 0x7fffffff;
      await _plugin.show(id, 'Входящий звонок', caller, details);
    } catch (e) {
      debugPrint('NOTIF CALL FAIL: $e');
    }
  }

  Future<void> cancelCall(String callId) async {
    if (!_ready) return;
    try {
      final id = callId.hashCode & 0x7fffffff;
      await _plugin.cancel(id);
    } catch (_) {}
  }

  /// Показ уведомлений о новых сообщениях из фонового изолята (WorkManager).
  /// В фоне нет инициализированного главного изолята, поэтому плагин
  /// инициализируем локально и показываем каждое сообщение отдельным
  /// уведомлением в канале 'messages'.
  Future<void> showBackgroundMessages(List<Map<String, String>> messages) async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await plugin.initialize(settings);
      final impl = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Канал сообщений мог ещё не существовать (приложение не открывалось).
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          'messages',
          'Сообщения',
          description: 'Уведомления о новых сообщениях',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Сообщения',
          channelDescription: 'Уведомления о новых сообщениях',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
        ),
      );
      for (final m in messages) {
        final id = DateTime.now().millisecondsSinceEpoch.hashCode & 0x7fffffff;
        await plugin.show(
          id,
          m['sender'] ?? 'Сообщение',
          m['text'] ?? '',
          details,
        );
        // Небольшая пауза, чтобы уведомления не слились в одно.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } catch (e) {
      debugPrint('BG NOTIF FAIL: $e');
    }
  }
}