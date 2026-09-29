import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/models/server_identity.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebsocketService {
  WebsocketService._();

  static final WebsocketService instance = WebsocketService._();

  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _controller;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _shouldReconnect = false;
  bool _connected = false;
  bool _connecting = false;
  DateTime? _lastPong;
  int _reconnectAttempt = 0;
  final List<Map<String, dynamic>> _pending = [];

  static const List<Duration> _backoffDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  Stream<Map<String, dynamic>> get events =>
      (_controller ??= StreamController<Map<String, dynamic>>.broadcast()).stream;

  bool get connected => _connected;

  void connect(ServerIdentity server) {
    _controller ??= StreamController<Map<String, dynamic>>.broadcast();
    _shouldReconnect = true;
    _reconnectAttempt = 0;
    _open(server);
    // Держим статус «онлайн»: периодически шлём ping, чтобы last_seen на
    // сервере обновлялся, иначе онлайн гаснет через 2 минуты даже при
    // открытом приложении (сервер трогает last_seen по ping).
    _pingTimer?.cancel();
    _lastPong = DateTime.now();
    _pingTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!_connected) return;
      final last = _lastPong;
      // Мёртвый сокет: ping уходит в пустоту, pong не приходит, ошибок нет.
      // Принудительно переподключаемся, иначе отправки исчезают молча.
      if (last != null &&
          DateTime.now().difference(last) > const Duration(seconds: 100)) {
        unawaited(CallLog.instance
            .write('WS stale (no pong), force reconnect'));
        try {
          _channel?.sink.close();
        } catch (_) {}
        _connected = false;
        final srv = _currentServer;
        if (srv != null && _shouldReconnect) _open(srv);
        return;
      }
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _open(ServerIdentity server) async {
    // Не запускаем второе подключение, пока предыдущее не завершилось.
    if (_connecting) return;
    _connecting = true;
    _connected = false;
    // Догрузка идентификатора устройства: если SecureStore.init() не
    // отработал, WS-подключение ушло бы с пустым/unknown device → 403.
    if (SecureStore.instance.deviceId.isEmpty) {
      try {
        await SecureStore.instance.init();
      } catch (_) {}
    }
    final token = server.token ?? '';
    final device = Uri.encodeQueryComponent(SecureStore.instance.deviceId);
    final url = '${server.wsUrl}/ws?token=$token&device=$device';
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      channel.stream.listen(
        (raw) {
          try {
            final event = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
            if (event['type'] == 'pong') {
              _lastPong = DateTime.now();
              return;
            }
            if (event['type'] == 'banned') {
              _controller?.add(event);
              _shouldReconnect = false;
            } else {
              _controller?.add(event);
            }
          } catch (_) {}
        },
        onDone: () {
          unawaited(CallLog.instance.write('WS onDone (closed by server)'));
          _scheduleReconnect();
        },
        onError: (e) {
          unawaited(CallLog.instance.write('WS onError: $e'));
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      // Считаем канал готовым ТОЛЬКО после реального подключения: иначе
      // send() в гонке с handshake бросает (WebSocketChannel not connected)
      // и сообщение теряется («Не доставлено»).
      try {
        await channel.ready;
      } catch (_) {
        _connecting = false;
        _scheduleReconnect();
        return;
      }
      _connected = true;
      _connecting = false;
      _reconnectAttempt = 0; // успех — сбрасываем backoff.
      _flushPending();
      // Явный запрос накопленных сообщений: только переднее приложение
      // отправляет sync_ready, фоновая проверка — нет.
      try {
        channel.sink.add(jsonEncode({'type': 'sync_ready'}));
      } catch (_) {}
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
    }
  }

  /// Повторная отправка сообщений, накопленных, пока соединения не было.
  void _flushPending() {
    if (_pending.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    final channel = _channel;
    if (channel != null) {
      for (final event in batch) {
        try {
          channel.sink.add(jsonEncode(event));
        } catch (_) {}
      }
    }
  }

  void _enqueue(Map<String, dynamic> event) {
    if (_pending.length < 200) {
      _pending.add(event);
    }
  }

  void _scheduleReconnect() {
    _connected = false;
    _reconnectTimer?.cancel();
    if (!_shouldReconnect) return;
    // Экспоненциальный backoff: 2с → 5с → 10с → 20с → 30с (потолок),
    // чтобы не долбить сервер ежесекундно мёртвыми подключениями.
    final delay = _backoffDelays[
        _reconnectAttempt < _backoffDelays.length ? _reconnectAttempt : _backoffDelays.length - 1];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      final server = _currentServer;
      if (server != null) _open(server);
    });
  }

  ServerIdentity? _currentServer;

  String? get currentServerDomain => _currentServer?.domain;

  String? get currentServerScheme => _currentServer?.scheme;

  int? get currentServerPort => _currentServer?.port;

  void setCurrentServer(ServerIdentity server) => _currentServer = server;

  void send(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel != null && _connected) {
      try {
        channel.sink.add(jsonEncode(event));
      } catch (_) {
        // Канал закрылся между проверкой и записью — не теряем сообщение,
        // уйдёт при переподключении (иначе пользователь видит «Не доставлено»).
        _enqueue(event);
      }
    } else {
      // Соединения нет — ставим в очередь; отправим при переподключении.
      _enqueue(event);
      // …и пробуем сразу HTTP-фолбэк; ушло — снимаем с очереди.
      final mid = event['msg_id']?.toString();
      unawaited(() async {
        try {
          await ApiClient.instance.syncSend(event);
          if (mid != null && mid.isNotEmpty) {
            _pending.removeWhere((e) => e['msg_id']?.toString() == mid);
          }
        } catch (_) {}
      }());
    }
  }

  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pingTimer = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _connected = false;
    unawaited(CallLog.instance.write('WS disconnect (explicit)'));
  }

  /// Фоновое «переподключение» WebSocket (вызывается из WorkManager).
  /// Пинг сервера /health + чтение накопленных сообщений из серверного буфера
  /// (sync_ready → flush_for). Расшифрованные сообщения возвращаются наружу,
  /// чтобы фоновый isolate показал уведомления (вариант C: «закрытое
  /// приложение → сообщения дойдут с задержкой до периодической задачи»).
  static Future<List<Map<String, String>>> reconnectFromBackground(
    String serversJson,
  ) async {
    final notifications = <Map<String, String>>[];
    try {
      await SecureStore.instance.init();
      await E2eeService.instance.init();
      final servers = jsonDecode(serversJson) as List<dynamic>;
      for (final serverData in servers) {
        try {
          final server = ServerIdentity.fromJson(
            Map<String, dynamic>.from(serverData as Map),
          );
          final token = await SecureStore.instance.readToken(server.domain);
          if (token == null || token.isEmpty) continue;
          // Лёгкий пинг /health без открытия WS-сессии.
          final uri = Uri.parse('${server.baseUrl}/health');
          final http = HttpClient()
            ..connectionTimeout = const Duration(seconds: 5);
          try {
            final req = await http.getUrl(uri);
            final res = await req.close();
            await res.drain<void>();
          } finally {
            http.close(force: true);
          }
          // Читаем накопленные сообщения: подключаемся, шлём sync_ready,
          // слушаем пару секунд, закрываем.
          final messages = await _fetchPending(
            server,
            token,
            httpClient: http,
          );
          notifications.addAll(messages);
        } catch (_) {
          // Сервер недоступен — следующая попытка через периодическую задачу.
        }
      }
    } catch (_) {
      // Игнорируем ошибки.
    }
    return notifications;
  }

  /// Открывает WS, шлёт `sync_ready`, читает входящие `message` до ~3 секунд
  /// и возвращает расшифрованные (senderUsername, text) для уведомлений.
  static Future<List<Map<String, String>>> _fetchPending(
    ServerIdentity server,
    String token, {
    HttpClient? httpClient,
  }) async {
    final result = <Map<String, String>>[];
    try {
    final device = Uri.encodeQueryComponent(SecureStore.instance.deviceId);
    final url =
        '${server.wsUrl}/ws?token=$token&device=$device';
    final channel = WebSocketChannel.connect(Uri.parse(url));
    await channel.ready.timeout(const Duration(seconds: 6));
      channel.sink.add(jsonEncode({'type': 'sync_ready'}));

      await Future<void>.delayed(const Duration(milliseconds: 300));

      await channel.stream
          .map((raw) {
            try {
              return Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
            } catch (_) {
              return null;
            }
          })
          .where((e) => e != null && e['type'] == 'message')
          .take(20)
          .timeout(const Duration(seconds: 3), onTimeout: (sink) => sink.close())
          .forEach((event) async {
            try {
              final eventMap = event as Map<String, dynamic>;
              final sender = eventMap['sender'] as Map? ?? const {};
              final username = sender['username']?.toString() ?? 'Сообщение';
              final payload = eventMap['payload'] as Map? ?? const {};
              final senderKey = payload['sender'] as String? ?? '';
              final ct = payload['ct'] as String? ?? '';
              var text = '';
              if (senderKey.isNotEmpty && ct.isNotEmpty) {
                try {
                  text = utf8.decode(
                    await E2eeService.instance.decryptFromPeer(senderKey, ct),
                  );
                } catch (_) {
                  text = 'Зашифрованное сообщение';
                }
              }
              if (text.isNotEmpty) {
                result.add({'sender': username, 'text': text});
              }
            } catch (_) {}
          });
      try {
        await channel.sink.close();
      } catch (_) {}
    } catch (_) {
      // Сбой соединения — игнорируем.
    }
    return result;
  }

  /// Отправка отложенного сообщения из фоновой задачи (workmanager).
  static Future<void> sendScheduledFromBackground(String payloadJson) async {
    try {
      await SecureStore.instance.init();
      final payload = Map<String, dynamic>.from(jsonDecode(payloadJson) as Map);
      final server = ServerIdentity.fromJson(
        Map<String, dynamic>.from(payload['server'] as Map),
      );
      final token = await SecureStore.instance.readToken(server.domain);
      final serverWithToken = ServerIdentity(
        domain: server.domain,
        name: server.name,
        scheme: server.scheme,
        port: server.port,
        token: token,
      );
      final device = Uri.encodeQueryComponent(SecureStore.instance.deviceId);
      final url =
          '${serverWithToken.wsUrl}/ws?token=$token&device=$device';
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      channel.sink.add(jsonEncode(payload['event']));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await channel.sink.close();
    } catch (_) {
      // Повторная попытка произойдёт при следующем запуске приложения.
    }
  }
}
