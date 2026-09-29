import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mesenger/core/security/topic_crypto.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/core/security/e2ee_service.dart';

/// Темы: отправка/приём через общий ключ комнаты (вариант А).
class TopicRepository {
  TopicRepository._();

  static final TopicRepository instance = TopicRepository._();

  static String chatIdFor(int topicId) => 'topic_$topicId';

  /// Раздать ключ комнаты участникам (у каждого нужен public_key).
  /// Возвращает число успешных отправок.
  Future<int> distributeKey(
    int topicId,
    String kid,
    String keyB64,
    List<Map<String, dynamic>> members,
  ) async {
    var ok = 0;
    for (final m in members) {
      final uid = (m['id'] as num?)?.toInt();
      final pub = m['public_key']?.toString() ?? '';
      if (uid == null || pub.isEmpty) continue;
      try {
        final env = await RoomCrypto.wrapKey(pub, topicId, kid, keyB64);
        WebsocketService.instance.send({
          'type': 'room_key',
          'msg_id': 'rk_${DateTime.now().microsecondsSinceEpoch}_$uid',
          'to': ['user:$uid'],
          'payload': env,
        });
        ok++;
      } catch (e) {
        debugPrint('ROOM KEY send FAIL uid=$uid: $e');
      }
    }
    return ok;
  }

  /// Создать ключ, сохранить локально, раздать участникам.
  Future<void> issueKey(int topicId) async {
    final res = await ApiClient.instance.topicMembers(topicId);
    final members =
        ((res['members'] as List? ?? const []).map((m) => Map<String, dynamic>.from(m as Map))).toList();
    final key = await RoomCrypto.newKey();
    final kid = await RoomCrypto.kidOf(key);
    await RoomKeyStore.set(topicId, kid, key);
    await distributeKey(topicId, kid, key, members);
  }

  /// Ротация после кика/выхода: новый ключ только оставшимся.
  Future<void> rotateKey(int topicId) => issueKey(topicId);

  /// Участники для выдачи ключа (с public_key).
  Future<List<Map<String, dynamic>>?> fetchMembersForKey(
      int topicId) async {
    try {
      final res = await ApiClient.instance.topicMembers(topicId);
      return ((res['members'] as List? ?? const [])
              .map((m) => Map<String, dynamic>.from(m as Map)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Попросить ключ у владельца темы (он раздаст фоном, если мы участник).
  Future<void> requestKey(int topicId, int ownerId) async {
    final me = await E2eeService.instance.publicKeyB64();
    WebsocketService.instance.send({
      'type': 'room_key_request',
      'msg_id': 'rkq_${DateTime.now().microsecondsSinceEpoch}',
      'topic_id': topicId,
      'to': ['user:$ownerId'],
      'payload': {'pubkey': me},
    });
  }

  /// Отправка текстового сообщения в тему.
  Future<void> sendMessage(int topicId, String text) async {
    final stored = RoomKeyStore.get(topicId);
    if (stored == null) {
      throw StateError('Нет ключа темы — запросите у владельца');
    }
    final env = await RoomCrypto.encrypt(
      stored['key'] as String,
      utf8.encode(text),
    );
    final msgId = 'm_${DateTime.now().microsecondsSinceEpoch}';
    WebsocketService.instance.send({
      'type': 'message',
      'msg_id': msgId,
      'topic_id': topicId,
      'to': ['topic:$topicId'],
      'payload': env,
    });
    await HiveService.instance.appendMessage(chatIdFor(topicId), {
      'id': msgId,
      'chatId': chatIdFor(topicId),
      'peerHandle': 'topic:$topicId',
      'payloadB64': text,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'outbound': true,
      'status': 'sent',
    });
  }
}
