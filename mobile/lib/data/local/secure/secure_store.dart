import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../../local/hive/hive_service.dart';
import '../../models/server_identity.dart' show ServerIdentity;

class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();
  final _storage = const FlutterSecureStorage();

  String deviceId = '';

  Future<void> init() async {
    deviceId = await _deviceId();
  }

  Future<String> _deviceId() async {
    // Сначала кэш: не ломаем существующие привязки на сервере.
    try {
      final cached = await _storage.read(key: 'device_id');
      if (cached != null && cached.isNotEmpty) return cached;
    } catch (_) {}
    // Детерминированный ID: переживает переустановки (тот же ANDROID_ID),
    // сервер узнаёт устройство без кода восстановления. После одного
    // восстановления по коду привязка станет стабильной навсегда.
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final stable = await _stableDeviceId(info);
      if (stable != null) {
        try {
          await _storage.write(key: 'device_id', value: stable);
        } catch (_) {}
        return stable;
      }
    } catch (_) {}
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final raw = '${info.id}-${info.model}-${info.brand}-${DateTime.now().microsecondsSinceEpoch}';
      final id = await _sha256Hex(raw);
      await _storage.write(key: 'device_id', value: id);
      return id;
    } catch (_) {
      // Защищённое хранилище недоступно — фолбэк в Hive (переживает
      // перезапуски), в крайнем случае случайный ID. deviceId никогда не пуст.
      try {
        final box = await _appBox();
        final cached = box.get('device_id') as String?;
        if (cached != null && cached.isNotEmpty) return cached;
        final rnd = Random.secure();
        final id = _encodeB64(List<int>.generate(16, (_) => rnd.nextInt(256)));
        await box.put('device_id', id);
        return id;
      } catch (_) {
        return 'unknown-${DateTime.now().millisecondsSinceEpoch}';
      }
    }
  }

  /// Стабильный ID устройства: sha256(ANDROID_ID + пакет).
  /// Возвращает null, если ANDROID_ID недоступен/мусорный.
  Future<String?> _stableDeviceId(dynamic androidInfo) async {
    try {
      final aid = androidInfo.id?.toString() ?? '';
      if (aid.isEmpty || aid == '9774d56d682e549c') return null;
      return await _sha256Hex('mesenger:$aid');
    } catch (_) {
      return null;
    }
  }

  String _encodeB64(List<int> bytes) => base64Encode(bytes);

  Future<String> _sha256Hex(String input) async {
    final digest = await Sha256().hash(utf8.encode(input));
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _randomB64(int bytes) {
    final rnd = Random.secure();
    final b = List<int>.generate(bytes, (_) => rnd.nextInt(256));
    return base64Encode(b);
  }

  // ---- Фолбэк-хранилище ----
  // При сбое flutter_secure_storage/Keystore (паттерн на устройстве
  // пользователя после переустановок) все данные сохраняются в Hive-бокс
  // 'app' — переживают перезапуски, приложение продолжает работать.
  Future<Box<dynamic>> _appBox() async {
    try {
      return HiveService.instance.app;
    } catch (_) {
      // HiveService ещё не инициализирован (hiveKey вызывается из его
      // init()) — открываем бокс напрямую, Hive.init уже выполнен.
      return Hive.openBox('app');
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      try {
        return (await _appBox()).get(key) as String?;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      try {
        await (await _appBox()).put(key, value);
      } catch (_) {}
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      try {
        await (await _appBox()).delete(key);
      } catch (_) {}
    }
  }

  // ---- Сессии ----
  Future<void> saveToken(String domain, String token) =>
      _write('token_$domain', token);

  Future<String?> readToken(String domain) => _read('token_$domain');

  Future<void> clearToken(String domain) => _delete('token_$domain');

  // ---- E2EE ----
  Future<void> writeE2eePrivate(String b64) => _write('e2ee_private', b64);

  Future<String?> readE2eePrivate() => _read('e2ee_private');

  // ---- Ключ Hive ----
  Future<String> hiveKey() async {
    final existing = await _read('hive_key');
    if (existing != null && existing.isNotEmpty) return existing;
    final key = _randomB64(32);
    await _write('hive_key', key);
    return key;
  }

  // ---- Реестр серверов (зашифрованный) ----
  Future<List<ServerIdentity>> loadServers() async {
    final raw = await _read('servers');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return list.map(ServerIdentity.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveServers(List<ServerIdentity> servers) async {
    final raw = jsonEncode(servers.map((s) => s.toJson()).toList());
    await _write('servers', raw);
  }

  // ---- Маркер «принять звонок из фона» ----
  // Когда колкит-событие accept приходит в ФОНОВЫЙ колбэк (движок главного
  // потока приостановлен), ответить на WS-уровне оттуда нельзя (нет WebRTC).
  // Поэтому пишем маркер с call_id, а главный изолят после возврата на
  // передний план подхватывает его и запускает acceptCall().
  Future<void> writeDeferredAccept(String callId) =>
      _write('deferred_accept', callId);

  Future<String?> readDeferredAccept() => _read('deferred_accept');

  Future<void> clearDeferredAccept() => _delete('deferred_accept');
}
