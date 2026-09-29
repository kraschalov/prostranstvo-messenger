import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mesenger/core/notifications/notification_service.dart';
import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/core/utils/maps.dart';
import 'package:mesenger/data/repositories/chat_repository.dart';
import 'package:mesenger/data/repositories/topic_repository.dart';
import 'package:mesenger/core/security/topic_crypto.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/data/remote/api_client.dart';

/// Глобальный приёмник входящих событий. Без него сообщение обрабатывалось
/// только при открытом чате — иначе терялось. Теперь входящие расшифровываются
/// и сохраняются в локальную историю независимо от открытого экрана, а список
/// чатов обновляется автоматически через Hive.watch().
class ChatSyncService {
  ChatSyncService._();

  static final ChatSyncService instance = ChatSyncService._();

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _httpPoll;

  void start() {
    _sub ??= WebsocketService.instance.events.listen(_handle);
    _httpPoll ??= Timer.periodic(const Duration(seconds: 20), (_) async {
      // HTTP-фолбэк: WS режут — забираем накопленное обычным запросом.
      if (WebsocketService.instance.connected) return;
      try {
        final res = await ApiClient.instance.syncPull();
        final events = (res['events'] as List? ?? const []);
        for (final e in events) {
          try {
            await _handle(Map<String, dynamic>.from(e as Map));
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  Future<void> _handle(Map<String, dynamic> event) async {
    final type = event['type'] as String?;
    final sender = asStringMap(event['sender']);
    if (sender == null) return;
    final chatId = 'dm_${sender['id']}';
    final msgId = event['msg_id'] as String?;

    switch (type) {
      case 'room_key':
        await _handleRoomKey(event);
        break;
      case 'room_key_request':
        await _handleRoomKeyRequest(event);
        break;
      case 'message':
        if (event['topic_id'] != null) {
          await _handleRoomMessage(event);
          break;
        }
        try {
          final message = await ChatRepository.instance.decryptIncoming(event);
          await ChatRepository.instance.storeIncoming(message);
          debugPrint('SYNC ok msg=$msgId text="${message.payloadB64}"');
          // Уведомление со звуком о новом сообщении.
          final body = message.payloadB64;
          if (body.isNotEmpty) {
            try {
              await NotificationService.instance.showMessage(
                title: message.peerHandle ?? 'Новое сообщение',
                body: body,
              );
            } catch (_) {}
          }
          // Подтверждение доставки отправителю, если чтение включено.
          if (_receiptsEnabled && msgId != null) {
            ChatRepository.instance.sendReceipt(
              senderId: sender['id'] as int,
              msgId: msgId,
              kind: 'delivered',
            );
          }
        } catch (e, st) {
          debugPrint('SYNC FAIL msg=$msgId from=${sender['id']}: $e\n$st');
          // Не удалось расшифровать — сообщение пропускается.
        }
        break;
      case 'delivered':
      case 'read':
        // Отправитель узнаёт статус своего исходящего сообщения.
        if (msgId != null && type != null) {
          await HiveService.instance.updateMessageStatus(msgId, type);
        }
        break;
      case 'edit':
        await _applyEdit(chatId, msgId, event);
        break;
      case 'delete':
        if (msgId != null) {
          await HiveService.instance.deleteMessageLocal(chatId, msgId);
        }
        break;
    }
  }

  /// Входящий ключ комнаты: 1-1 конверт -> сохранить локально.
  Future<void> _handleRoomKey(Map<String, dynamic> event) async {
    try {
      final payload = asStringMap(event['payload']);
      final senderKey = payload?['sender'] as String? ?? '';
      final ct = payload?['ct'] as String? ?? '';
      if (senderKey.isEmpty || ct.isEmpty) return;
      final raw = utf8.decode(
        await E2eeService.instance.decryptFromPeer(senderKey, ct),
      );
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final tid = (data['topic_id'] as num?)?.toInt();
      final kid = data['kid']?.toString() ?? '';
      final key = data['key']?.toString() ?? '';
      if (tid == null || kid.isEmpty || key.isEmpty) return;
      await RoomKeyStore.set(tid, kid, key);
      debugPrint('ROOM KEY stored topic=$tid kid=$kid');
    } catch (e) {
      debugPrint('ROOM KEY FAIL: $e');
    }
  }

  /// Входящее сообщение темы: расшифровать ключом комнаты.
  Future<void> _handleRoomMessage(Map<String, dynamic> event) async {
    final tid = (event['topic_id'] as num?)?.toInt();
    final msgId = event['msg_id'] as String?;
    if (tid == null) return;
    try {
      final payload = asStringMap(event['payload']);
      final ct = payload?['ct'] as String? ?? '';
      final stored = RoomKeyStore.get(tid);
      if (ct.isEmpty || stored == null) return;
      final text = utf8.decode(
        await RoomCrypto.decrypt(stored['key'] as String, ct),
      );
      final sender = asStringMap(event['sender']);
      await HiveService.instance.appendMessage(
        TopicRepository.chatIdFor(tid),
        {
          'id': msgId ?? 'm_${DateTime.now().microsecondsSinceEpoch}',
          'chatId': TopicRepository.chatIdFor(tid),
          'peerHandle': 'topic:$tid',
          'payloadB64': text,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'outbound': false,
          'status': 'delivered',
          'unread': true,
          'senderId': sender?['id'],
          'senderName': sender?['username']?.toString() ?? '',
        },
      );
      if (text.isNotEmpty) {
        try {
          await NotificationService.instance.showMessage(
            title: 'Тема',
            body: text,
          );
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('ROOM MSG FAIL topic=$tid: $e');
    }
  }

  /// Запрос ключа: если проситель — участник темы, шлём ему ключ.
  /// Работает фоном, закрывает все случаи потери (офлайн, переустановка).
  Future<void> _handleRoomKeyRequest(Map<String, dynamic> event) async {
    try {
      final sender = asStringMap(event['sender']);
      final fromId = (sender?['id'] as num?)?.toInt();
      final tid = (event['topic_id'] as num?)?.toInt();
      if (fromId == null || tid == null) return;
      final stored = RoomKeyStore.get(tid);
      if (stored == null) return;
      final res =
          await TopicRepository.instance.fetchMembersForKey(tid);
      if (res == null) return;
      Map<String, dynamic>? target;
      for (final m in res) {
        if ((m['id'] as num?)?.toInt() == fromId) {
          target = m;
          break;
        }
      }
      if (target == null) return;
      await TopicRepository.instance.distributeKey(
        tid,
        stored['kid'] as String,
        stored['key'] as String,
        [target],
      );
      debugPrint('ROOM KEY served topic=$tid uid=$fromId');
    } catch (e) {
      debugPrint('ROOM KEY REQUEST FAIL: $e');
    }
  }

  bool get _receiptsEnabled =>
      HiveService.instance.settings['show_receipts'] as bool? ?? true;

  Future<void> _applyEdit(
    String chatId,
    String? msgId,
    Map<String, dynamic> event,
  ) async {
    if (msgId == null) return;
    final history = HiveService.instance.chatHistory(chatId);
    final index = history.indexWhere((m) => m['id'] == msgId);
    if (index < 0) return;
    final payload = asStringMap(event['payload']);
    final senderKey = payload?['sender'] as String? ?? '';
    final ct = payload?['ct'] as String? ?? '';
    if (senderKey.isEmpty || ct.isEmpty) return;
    try {
      final text = utf8.decode(
        await E2eeService.instance.decryptFromPeer(senderKey, ct),
      );
      history[index]['payloadB64'] = text;
      history[index]['editedAt'] = DateTime.now().toIso8601String();
      await HiveService.instance.chats.put(chatId, history);
    } catch (_) {}
  }
}
