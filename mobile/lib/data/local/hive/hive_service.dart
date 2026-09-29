import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../secure/secure_store.dart';

class HiveService {
  HiveService._();

  static final HiveService instance = HiveService._();

  late Box<dynamic> app;
  late Box<dynamic> chats;
  late Box<dynamic> contacts;

  /// Строка диагностики: что с хранилищем на этом устройстве.
  String lastInitError = '';

  Future<void> init() async {
    lastInitError = '';
    try {
      final dir = await getApplicationDocumentsDirectory();
      Hive.init(dir.path);
    } catch (e) {
      lastInitError = 'Hive.init: $e';
      debugPrint('HIVE INIT FAIL: $e');
    }
    // Каждый бокс открывается независимо: сбой одного не ломает остальные.
    // app — без шифрования (настройки, фолбэк SecureStore).
    try {
      app = await Hive.openBox('app');
    } catch (e) {
      lastInitError += '; app: $e';
      debugPrint('HIVE app FAIL: $e');
    }
    // Шифрованные боксы: если файл создан под другим/потерянным ключом,
    // openBox бросает — пересоздаём, иначе список чатов/контактов навсегда
    // «крутит загрузку» и добавление контактов молча не сохраняется.
    chats = await _openEncrypted('chats');
    contacts = await _openEncrypted('contacts');
    debugPrint('HIVE READY app=${_boxOk(app)} chats=${_boxOk(chats)} '
        'contacts=${_boxOk(contacts)} err=$lastInitError');
  }

  bool _boxOk(Box<dynamic> box) => box.isOpen;

  Future<Box<dynamic>> _openEncrypted(String name) async {
    try {
      final key = base64Decode(await SecureStore.instance.hiveKey());
      final box = await Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
      return box;
    } catch (e) {
      debugPrint('HIVE $name FAIL ($e) — пересоздаю бокс');
      lastInitError += '; $name: $e';
      try {
        await Hive.deleteBoxFromDisk(name);
        final key = base64Decode(await SecureStore.instance.hiveKey());
        return await Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
      } catch (e2) {
        debugPrint('HIVE $name RECREATE FAIL: $e2');
        lastInitError += '; $name-recreate: $e2';
        // Последняя страховка: открываем без шифрования, лишь бы жить.
        return Hive.openBox('${name}_plain');
      }
    }
  }

  // ---- Настройки приложения ----
  Map<String, dynamic> get settings =>
      Map<String, dynamic>.from(app.get('settings', defaultValue: const {}));

  Future<void> saveSettings(Map<String, dynamic> value) =>
      app.put('settings', value);

  /// Закреплённые в общих «Чатах» темы (chatId вида topic_N).
  /// По умолчанию темы скрыты и живут только в подразделе «Темы».
  List<String> get pinnedTopicChats {
    final v = settings['pinned_topic_chats'];
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  Future<void> setTopicPinned(String chatId, bool pinned) async {
    final cur = pinnedTopicChats.toList();
    if (pinned && !cur.contains(chatId)) {
      cur.add(chatId);
    } else if (!pinned) {
      cur.remove(chatId);
    }
    final all = settings;
    all['pinned_topic_chats'] = cur;
    await saveSettings(all);
  }

  // ---- История чатов (локально, зашифровано) ----
  List<dynamic> chatHistory(String chatId) =>
      List<dynamic>.from(chats.get(chatId, defaultValue: const []));

  Future<void> appendMessage(String chatId, Map<String, dynamic> message) async {
    final list = chatHistory(chatId);
    list.add(message);
    await chats.put(chatId, list);
  }

  Future<void> replaceMessage(String chatId, String msgId, Map<String, dynamic> message) async {
    final list = chatHistory(chatId);
    final index = list.indexWhere((m) => m['id'] == msgId);
    if (index >= 0) {
      list[index] = message;
      await chats.put(chatId, list);
    }
  }

  /// Обновление статуса исходящего сообщения по его id (например, доставлено,
  /// прочитано). Если чат неизвестен — ищем по всем ключам бокса.
  /// Запоминаем момент смены статуса (statusAt, мс), чтобы показывать время.
  Future<void> updateMessageStatus(String msgId, String status) async {
    try {
      for (final key in chats.keys) {
        final list = chatHistory(key);
        final index = list.indexWhere((m) => m is Map && m['id'] == msgId);
        if (index >= 0 && list[index]['status'] != status) {
          if (status == 'delivered' || status == 'read') {
            list[index]['statusAt'] = DateTime.now().millisecondsSinceEpoch;
          }
          list[index]['status'] = status;
          await chats.put(key, list);
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> deleteMessageLocal(String chatId, String msgId) async {
    final list = chatHistory(chatId);
    final index = list.indexWhere((m) => m['id'] == msgId);
    if (index >= 0) {
      list[index]['deleted'] = true;
      await chats.put(chatId, list);
    }
  }

  /// Помечает все входящие сообщения чата прочитанными (unread=false).
  /// Вызывается при открытии чата, чтобы снять зелёную точку в списке.
  Future<void> markChatRead(String chatId) async {
    try {
      final list = chatHistory(chatId);
      var changed = false;
      for (final m in list) {
        if (m is Map && m['outbound'] != true && m['unread'] == true) {
          m['unread'] = false;
          changed = true;
        }
      }
      if (changed) {
        await chats.put(chatId, list);
      }
    } catch (_) {}
  }

  /// Есть ли непрочитанные входящие в чате (в т.ч. темы topic_N).
  bool chatHasUnread(String chatId) {
    try {
      for (final m in chatHistory(chatId)) {
        if (m is Map && m['outbound'] != true && m['unread'] == true) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Есть ли непрочитанное хоть в одной теме (для точки на кнопке «Темы»).
  bool get anyTopicUnread {
    try {
      for (final key in chats.keys) {
        if (key is String &&
            key.startsWith('topic_') &&
            chatHasUnread(key)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  // ---- Контакты ----
  List<dynamic> get contactsList =>
      List<dynamic>.from(contacts.get('list', defaultValue: const []));

  Future<void> addContact(Map<String, dynamic> contact) async {
    final list = contactsList;
    if (!list.any((c) => c['handle'] == contact['handle'])) {
      list.add(contact);
      await contacts.put('list', list);
    }
  }

  /// Обновление контакта (например, новый E2EE-ключ собеседника).
  /// Ищем по id или chatId (handle может отличаться форматом: с доменом
  /// и без), иначе — добавляем. Сохраняем chatId, чтобы чат находил
  /// актуальный контакт (chat_screen ищет по chatId).
  /// Удаление контакта из «Близких» (по id).
  Future<void> removeContact(int id) async {
    final list = contactsList;
    list.removeWhere((c) => c is Map && (c['id'] as num?)?.toInt() == id);
    await contacts.put('list', list);
  }

  Future<void> updateContact(Map<String, dynamic> contact) async {
    final list = contactsList;
    final cid = contact['id'];
    final chatId = contact['chatId'];
    int? index;
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      if (c is Map) {
        if (cid != null && c['id'] == cid) {
          index = i;
          break;
        }
        if (chatId != null && c['chatId'] == chatId) {
          index = i;
          break;
        }
      }
    }
    final merged = <String, dynamic>{};
    if (index != null) {
      merged.addAll(Map<String, dynamic>.from(list[index] as Map));
    }
    // Пустые поля из обновления не должны затирать существующие
    // (например, server: событие его не передаёт).
    final incoming = Map<String, dynamic>.from(contact);
    incoming.forEach((key, value) {
      if (value != null && value.toString().isNotEmpty) {
        merged[key] = value;
      }
    });
    merged['chatId'] = chatId ?? merged['chatId'] ?? 'dm_${cid}';
    if (index != null) {
      list[index] = merged;
    } else {
      list.add(merged);
    }
    await contacts.put('list', list);
  }
}
