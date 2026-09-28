import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../data/local/secure/secure_store.dart';

class E2eeService {
  E2eeService._();

  static final E2eeService instance = E2eeService._();
  final _alg = X25519();
  SimpleKeyPair? _pair;

  Future<void> init() async {
    // Ключ читается через SecureStore (фолбэк в Hive при сбое Keystore):
    // раньше здесь был прямой FlutterSecureStorage — на устройстве со
    // сломанным secure-хранилищем чтение падало, _pair оставался null,
    // и отправка умирала на _pair! («Не доставлено»).
    try {
      final stored = await SecureStore.instance.readE2eePrivate();
      if (stored != null && stored.isNotEmpty) {
        _pair = await _alg.newKeyPairFromSeed(_decodeB64(stored));
        return;
      }
    } catch (e) {
      debugPrint('E2EE read FAIL: $e');
    }
    // Ключа нет или хранилище сломалось — генерируем новый. _pair никогда
    // не остаётся null, отправка работает в любом случае.
    final pair = await _alg.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    try {
      await SecureStore.instance.writeE2eePrivate(_encodeB64(seed));
    } catch (_) {}
    _pair = pair;
  }

  Future<String> publicKeyB64() async {
    final pub = await _pair!.extractPublicKey();
    return _encodeB64(pub.bytes);
  }

  /// Шифрование для собеседника по его статическому открытому ключу (X25519
  /// + XChaCha20-Poly1305). Статический DH достаточен: аккаунт жёстко
  /// привязан к одному устройству.
  Future<Map<String, dynamic>> encryptForPeer(
    String peerPublicKeyB64,
    List<int> plaintext,
  ) async {
    final peerPub =
        SimplePublicKey(_decodeB64(peerPublicKeyB64), type: KeyPairType.x25519);
    final shared = await _alg.sharedSecretKey(keyPair: _pair!, remotePublicKey: peerPub);
    final secretKey = SecretKey(await shared.extractBytes());
    final alg = Xchacha20.poly1305Aead();
    final nonce = _random(24);
    final box = await alg.encrypt(plaintext, secretKey: secretKey, nonce: nonce);
    final ct = [...nonce, ...box.cipherText, ...box.mac.bytes];
    return {
      'v': 1,
      'ct': _encodeB64(ct),
      'sender': await publicKeyB64(),
    };
  }

  Future<List<int>> decryptFromPeer(
    String senderPublicKeyB64,
    String cipherB64,
  ) async {
    final senderPub =
        SimplePublicKey(_decodeB64(senderPublicKeyB64), type: KeyPairType.x25519);
    final shared = await _alg.sharedSecretKey(keyPair: _pair!, remotePublicKey: senderPub);
    final secretKey = SecretKey(await shared.extractBytes());
    final alg = Xchacha20.poly1305Aead();
    final bytes = _decodeB64(cipherB64);
    if (bytes.length < 24 + 16) {
      throw const FormatException('Некорректный зашифрованный пакет');
    }
    final nonce = bytes.sublist(0, 24);
    final cipher = bytes.sublist(24, bytes.length - 16);
    final mac = bytes.sublist(bytes.length - 16);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    return alg.decrypt(box, secretKey: secretKey);
  }

  List<int> _random(int n) {
    final rnd = Random.secure();
    return List<int>.generate(n, (_) => rnd.nextInt(256));
  }

  String _encodeB64(List<int> bytes) => base64Encode(bytes);

  List<int> _decodeB64(String s) => base64Decode(s);
}
