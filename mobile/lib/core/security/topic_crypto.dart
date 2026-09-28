import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../../data/local/hive/hive_service.dart';
import 'e2ee_service.dart';

/// Крипта варианта А: общий ключ комнаты.
class RoomCrypto {
  RoomCrypto._();

  static final _aead = Xchacha20.poly1305Aead();

  /// Новый 256-битный ключ комнаты (base64).
  static Future<String> newKey() async {
    final k = await SecretKeyData.random(length: 32).extractBytes();
    return base64Encode(k);
  }

  /// Короткий id ключа для envelope (первые 12 hex sha256).
  static Future<String> kidOf(String keyB64) async {
    final d = await Sha256().hash(base64Decode(keyB64));
    return d.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 12);
  }

  static List<int> _rnd(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  /// Шифрование сообщения ключом комнаты. Возвращает envelope для relay.
  static Future<Map<String, dynamic>> encrypt(
    String keyB64,
    List<int> plaintext,
  ) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(base64Decode(keyB64)),
      nonce: _rnd(24),
    );
    return {
      'v': 2,
      'kid': await kidOf(keyB64),
      'ct': base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]),
      'sender': await E2eeService.instance.publicKeyB64(),
    };
  }

  /// Расшифровка envelope комнаты.
  static Future<List<int>> decrypt(String keyB64, String ctB64) async {
    final bytes = base64Decode(ctB64);
    if (bytes.length < 24 + 16) {
      throw const FormatException('Некорректный пакет комнаты');
    }
    final box = SecretBox(
      bytes.sublist(24, bytes.length - 16),
      nonce: bytes.sublist(0, 24),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    return _aead.decrypt(box, secretKey: SecretKey(base64Decode(keyB64)));
  }

  /// Завернуть ключ комнаты для участника (его публичным ключом).
  static Future<Map<String, dynamic>> wrapKey(
    String memberPublicKeyB64,
    int topicId,
    String kid,
    String keyB64,
  ) {
    return E2eeService.instance.encryptForPeer(
      memberPublicKeyB64,
      utf8.encode(jsonEncode({'topic_id': topicId, 'kid': kid, 'key': keyB64})),
    );
  }
}

/// Локальное хранилище ключей комнат (box app, ключ 'room_keys').
class RoomKeyStore {
  RoomKeyStore._();

  static Map<String, dynamic> _all() {
    final v = HiveService.instance.app.get('room_keys');
    if (v is Map) return Map<String, dynamic>.from(v);
    return {};
  }

  static Map<String, dynamic>? get(int topicId) {
    final v = _all()['$topicId'];
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static Future<void> set(int topicId, String kid, String keyB64) async {
    final all = _all();
    all['$topicId'] = {'kid': kid, 'key': keyB64};
    await HiveService.instance.app.put('room_keys', all);
  }

  static Future<void> remove(int topicId) async {
    final all = _all();
    all.remove('$topicId');
    await HiveService.instance.app.put('room_keys', all);
  }
}
