import 'dart:convert';

import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/core/utils/maps.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/models/chat_message.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:workmanager/workmanager.dart';

class ChatRepository {
  ChatRepository._();

  static final ChatRepository instance = ChatRepository._();

  String chatIdFor(UserProfile peer) => 'dm_${peer.id}';

  String _targetFor(UserProfile me, UserProfile peer) {
    final current = _currentDomain();
    // Пустой server означает «тот же сервер, что и у меня».
    final peerServer = peer.server.isEmpty ? current : peer.server;
    if (peerServer == current) {
      return 'user:${peer.id}';
    }
    return 'remote:$peerServer:${peer.id}';
  }

  String _currentDomain() {
    final server = WebsocketService.instance.currentServerDomain;
    return server ?? '';
  }

  String get _serverScheme =>
      WebsocketService.instance.currentServerScheme ?? 'https';

  int? get _serverPort => WebsocketService.instance.currentServerPort;

  Future<Map<String, dynamic>> encryptText(
    UserProfile peer,
    String text,
  ) async {
    return E2eeService.instance.encryptForPeer(peer.publicKey, utf8.encode(text));
  }

  Future<void> sendMessage(
    UserProfile peer,
    String text,
  ) async {
    final envelope = await encryptText(peer, text);
    final msgId = 'm_${DateTime.now().microsecondsSinceEpoch}';
    final event = {
      'type': 'message',
      'msg_id': msgId,
      'to': [_targetFor(peer, peer)],
      'payload': envelope,
    };
    WebsocketService.instance.send(event);
    await HiveService.instance.appendMessage(chatIdFor(peer), {
      'id': msgId,
      'chatId': chatIdFor(peer),
      'peerHandle': peer.handle,
      'payloadB64': text,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'outbound': true,
      'status': 'sent',
    });
  }

  /// Отправка вложения (файл/картинка): файл уже загружен на сервер,
  /// [meta] — ответ /api/upload/chat (file_id/name/size/mime/url).
  /// Метаданные вложения шифруются как обычный текст — получатель видит
  /// карточку файла, а скачивание запускает сам по явному согласию.
  Future<void> sendFileMessage(
    UserProfile peer, {
    required Map<String, dynamic> meta,
    String? caption,
  }) async {
    final payload = {
      if (caption != null && caption.isNotEmpty) 'text': caption,
      'attachment': meta,
    };
    final envelope = await E2eeService.instance
        .encryptForPeer(peer.publicKey, utf8.encode(jsonEncode(payload)));
    final msgId = 'm_${DateTime.now().microsecondsSinceEpoch}';
    final event = {
      'type': 'message',
      'msg_id': msgId,
      'to': [_targetFor(peer, peer)],
      'payload': envelope,
    };
    WebsocketService.instance.send(event);
    await HiveService.instance.appendMessage(chatIdFor(peer), {
      'id': msgId,
      'chatId': chatIdFor(peer),
      'peerHandle': peer.handle,
      'payloadB64': caption ?? '',
      'attachment': meta,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'outbound': true,
      'status': 'sent',
    });
  }

  Future<void> editMessage(
    UserProfile peer,
    String msgId,
    String text,
  ) async {
    final envelope = await encryptText(peer, text);
    WebsocketService.instance.send({
      'type': 'edit',
      'msg_id': msgId,
      'to': [_targetFor(peer, peer)],
      'payload': envelope,
    });
  }

  Future<void> deleteForAll(UserProfile peer, String msgId) async {
    WebsocketService.instance.send({
      'type': 'delete',
      'msg_id': msgId,
      'to': [_targetFor(peer, peer)],
    });
  }

  Future<void> deleteForMe(String chatId, String msgId) async {
    await HiveService.instance.deleteMessageLocal(chatId, msgId);
  }

  /// Отложенная отправка: событие уходит на сервер (там держится в RAM)
  /// и дополнительно регистрируется фоновая задача для надёжности.
  Future<void> scheduleMessage(
    UserProfile peer,
    String text,
    DateTime at,
  ) async {
    final envelope = await encryptText(peer, text);
    final msgId = 'm_${DateTime.now().microsecondsSinceEpoch}';
    final event = {
      'type': 'schedule',
      'at': at.millisecondsSinceEpoch / 1000,
      'msg_id': msgId,
      'to': [_targetFor(peer, peer)],
      'payload': envelope,
    };
    WebsocketService.instance.send(event);
    await HiveService.instance.appendMessage(chatIdFor(peer), {
      'id': msgId,
      'chatId': chatIdFor(peer),
      'peerHandle': peer.handle,
      'payloadB64': text,
      'createdAt': at.millisecondsSinceEpoch,
      'outbound': true,
      'status': 'scheduled',
    });
    final delay = at.difference(DateTime.now());
    if (delay.isNegative) return;
    await Workmanager().registerOneOffTask(
      msgId,
      'sendScheduledMessage',
      inputData: {
        'payload': jsonEncode({
          'server': {
            'domain': WebsocketService.instance.currentServerDomain,
            'name': '',
            'scheme': _serverScheme,
            'port': _serverPort,
          },
          'event': event,
        }),
      },
      initialDelay: delay,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  /// Отправка подтверждения доставки/прочтения отправителю.
  void sendReceipt({required int senderId, required String? msgId, required String kind}) {
    if (msgId == null || msgId.isEmpty) return;
    final target = _targetForSelf(senderId);
    if (target == null) return;
    WebsocketService.instance.send({
      'type': kind,
      'msg_id': msgId,
      'to': [target],
    });
  }

  /// Адрес отправителя для ответного подтверждения (тот же сервер/удалённый).
  String? _targetForSelf(int senderId) {
    final peer = UserProfile(
      id: senderId,
      username: '',
      handle: '',
      displayName: '',
      gender: 'unknown',
      age: 0,
      city: '',
      goal: '',
      interests: const [],
      bio: '',
      photoPath: '',
        coverPath: '',
      role: 'STANDARD_USER',
      publicKey: '',
      server: '',
      online: false,
    );
    return _targetFor(peer, peer);
  }

  /// Пометить входящие сообщения собеседника как прочитанные: шлём
  /// подтверждения `read` по их msg_id (только если отображение включено).
  void markIncomingRead({required int senderId, required List<String> msgIds}) {
    if (msgIds.isEmpty) return;
    for (final id in msgIds) {
      sendReceipt(senderId: senderId, msgId: id, kind: 'read');
    }
  }

  Future<ChatMessage> decryptIncoming(
    Map<String, dynamic> event,
  ) async {
    final payload = asStringMap(event['payload']) ?? {};
    final senderKey = payload['sender'] as String? ?? '';
    final ct = payload['ct'] as String? ?? '';
    final decrypted = utf8.decode(
      await E2eeService.instance.decryptFromPeer(senderKey, ct),
    );
    // Полезная нагрузка может быть как обычным текстом, так и JSON
    // {"text": "...", "attachment": {...}} для вложений.
    String text = decrypted;
    Map<String, dynamic>? attachment;
    try {
      final decoded = jsonDecode(decrypted);
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        if (map['attachment'] is Map) {
          attachment = Map<String, dynamic>.from(map['attachment'] as Map);
          text = map['text']?.toString() ?? '';
        }
      }
    } catch (_) {
      // Это просто текст — оставляем как есть.
    }
    final sender = asStringMap(event['sender']) ?? {};
    final chatId = 'dm_${sender['id']}';
    // Собеседник передаёт свой текущий публичный ключ прямо в сообщении.
    // Обновляем контакт: после сбоя хранилища ключ мог пересоздаться, и
    // шифрование ответа на устаревший ключ сделало бы его нечитабельным.
    if (senderKey.isNotEmpty && sender['id'] != null) {
      try {
        await HiveService.instance.updateContact({
          'id': sender['id'],
          'chatId': chatId,
          'handle': '@${sender['username']}' as dynamic,
          'publicKey': senderKey,
          'server': sender['server'] ?? '',
        });
      } catch (_) {}
    }
    return ChatMessage(
      id: event['msg_id'] as String? ?? '',
      chatId: chatId,
      peerHandle: '@${sender['username']}',
      payloadB64: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      outbound: false,
      unread: true,
      attachment: attachment != null
          ? ChatAttachment.fromJson(attachment)
          : null,
    );
  }

  Future<void> storeIncoming(ChatMessage message) async {
    await HiveService.instance.appendMessage(message.chatId, message.toJson());
  }
}
