import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/app.dart';
import 'package:mesenger/core/calls/call_service.dart';
import 'package:mesenger/core/notifications/notification_service.dart';
import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/data/services/chat_sync_service.dart';
import 'package:mesenger/data/services/foreground_service.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final action = task;
    final payload = inputData?['payload'] as String?;
    if (action == 'sendScheduledMessage' && payload != null) {
      await WebsocketService.sendScheduledFromBackground(payload);
    }
    if (action == 'reconnectWebsocket') {
      final serversData = inputData?['servers'] as String?;
      if (serversData != null) {
        // Вариант C: фоновый запуск читает накопленные сообщения из буфера
        // сервера и показывает уведомления, даже если приложение закрыто.
        final messages =
            await WebsocketService.reconnectFromBackground(serversData);
        if (messages.isNotEmpty) {
          await NotificationService.instance.showBackgroundMessages(messages);
        }
      }
    }
    return true;
  });
}

/// Фоновый колбэк flutter_callkit_incoming: вызывается в отдельном, специально
/// созданном плагином FlutterEngine, когда главный движок приостановлен/убит
/// (входящий звонок при свёрнутом приложении). Здесь нельзя полноценно
/// ответить вызовом по WebRTC — главный изолят при возврате на передний план
/// подхватит маркер и вызовет acceptCall(). Поэтому только пишем/чистим маркер.
@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent event) async {
  try {
    await SecureStore.instance.init();
    final name = event.eventName;
    if (name == CallEventConstants.actionCallAccept) {
      final accept = event as CallEventActionCallAccept;
      final id = accept.callKitParams.id ?? 'call';
      await SecureStore.instance.writeDeferredAccept(id);
      debugPrint('BG CALLKIT ACCEPT -> $id');
    } else if (name == CallEventConstants.actionCallDecline ||
        name == CallEventConstants.actionCallEnded ||
        name == CallEventConstants.actionCallTimeout) {
      await SecureStore.instance.clearDeferredAccept();
      debugPrint('BG CALLKIT $name (clear marker)');
    }
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Разрешаем HTTP (cleartext) для Image.network и других dart:io запросов:
  // манифест usesCleartextTraffic="true" влияет только на платформенные
  // клиенты, а Flutter Image.network использует свой HttpClient, который без
  // HttpOverrides блокирует http на Android 9+.
  HttpOverrides.global = _AllowHttpOverrides();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('=== FLUTTER ERROR ===\n${details.exception}\n${details.stack}');
  };
  runZonedGuarded(() async {
    await _bootstrap();
    runApp(const ProviderScope(child: MesengerApp()));
  }, (error, stack) {
    debugPrint('=== ZONE ERROR ===\n$error\n$stack');
  });
}

class _AllowHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // Разрешаем любой HTTP-запрос (наш сервер может быть без TLS).
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

Future<void> _bootstrap() async {
  // Каждая инициализация — fail-soft: интерфейс запускается ВСЕГДА,
  // иначе ошибочная инициализация даёт чёрный экран.
  try {
    await HiveService.instance.init();
  } catch (e) {
    debugPrint('HIVE INIT FAIL: $e');
  }
  try {
    await E2eeService.instance.init();
  } catch (e) {
    debugPrint('E2EE INIT FAIL: $e');
  }
  try {
    await SecureStore.instance.init();
  } catch (e) {
    debugPrint('SECURE INIT FAIL: $e');
  }
  ChatSyncService.instance.start();
  CallService.instance.start();
  // Фоновый колбэк колкита: при «Ответить» в свёрнутом приложении событие
  // accept уходит в фоновый движок, наш колбэк пишет маркер в SecureStore,
  // и при возврате на передний план acceptDeferredIfPending() завершит вызов.
  try {
    await FlutterCallkitIncoming.onBackgroundMessage(callkitBackgroundHandler);
  } catch (e) {
    debugPrint('CALLKIT BG REG FAIL: $e');
  }
  try {
    await NotificationService.instance.init();
  } catch (e) {
    debugPrint('NOTIF INIT FAIL: $e');
  }
  // Постоянный фоновый сервис: держит процесс/WS живым при свёрнутом
  // приложении, чтобы сообщения и звонки доходили сразу.
  try {
    ForegroundService.instance.init();
  } catch (e) {
    debugPrint('FG SERVICE INIT FAIL: $e');
  }
  try {
    await Workmanager().initialize(callbackDispatcher);
  } catch (e) {
    debugPrint('WORKMANAGER INIT FAIL: $e');
  }
  try {
    await _registerPeriodicTasks();
  } catch (e) {
    debugPrint('WORKMANAGER TASKS FAIL: $e');
  }
}

Future<void> _registerPeriodicTasks() async {
  final servers = await SecureStore.instance.loadServers();
  final serversJson = jsonEncode(servers.map((s) => s.toJson()).toList());
  await Workmanager().registerPeriodicTask(
    'reconnectWebsocket',
    'reconnectWebsocket',
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    initialDelay: const Duration(minutes: 1),
    inputData: {'servers': serversJson},
  );
}
