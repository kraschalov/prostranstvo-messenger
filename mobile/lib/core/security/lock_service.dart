import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/core/state/app_state.dart';

class LockService {
  LockService._();

  static final LockService instance = LockService._();
  final _auth = LocalAuthentication();
  final _rand = Random.secure();

  Map<String, dynamic> get _cfg =>
      Map<String, dynamic>.from(HiveService.instance.app.get('lock', defaultValue: const {}));

  Future<bool> biometricAvailable() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Подтвердите биометрию',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> saveSecret(LockType type, String secret) async {
    final salt = _rand.nextInt(1 << 31).toRadixString(16);
    final hash = await _hash('$salt::$secret');
    final cfg = _cfg;
    cfg['type'] = type.name;
    cfg['salt'] = salt;
    cfg['hash'] = hash;
    await HiveService.instance.app.put('lock', cfg);
  }

  Future<bool> verify(String secret) async {
    final cfg = _cfg;
    final salt = cfg['salt'] as String?;
    final hash = cfg['hash'] as String?;
    if (salt == null || hash == null) return false;
    final candidate = await _hash('$salt::$secret');
    return candidate == hash;
  }

  Future<String> _hash(String input) async {
    final digest = await Sha256().hash(utf8.encode(input));
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
