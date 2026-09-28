import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/models/server_identity.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/data/services/foreground_service.dart';

enum LockType { none, biometric, pin, pattern, password }

class AppState {
  final bool bootstrapped;
  final List<ServerIdentity> servers;
  final int activeIndex;
  final UserProfile? user;
  final bool banned;
  final bool lockEnabled;
  final LockType lockType;
  final bool lockUnlocked;
  /// Глубокая ссылка приглашения (protoapp://join?code=...&server=...),
  /// открытая до/во время онбординга. Применяется на eslintонбординг-экранах.
  final String? pendingInvite;

  const AppState({
    this.bootstrapped = false,
    this.servers = const [],
    this.activeIndex = 0,
    this.user,
    this.banned = false,
    this.lockEnabled = false,
    this.lockType = LockType.none,
    this.lockUnlocked = false,
    this.pendingInvite,
  });

  ServerIdentity? get activeServer =>
      servers.isEmpty ? null : servers[activeIndex.clamp(0, servers.length - 1)];

  AppState copyWith({
    bool? bootstrapped,
    List<ServerIdentity>? servers,
    int? activeIndex,
    UserProfile? user,
    bool? banned,
    bool? lockEnabled,
    LockType? lockType,
    bool? lockUnlocked,
    String? pendingInvite,
  }) {
    return AppState(
      bootstrapped: bootstrapped ?? this.bootstrapped,
      servers: servers ?? this.servers,
      activeIndex: activeIndex ?? this.activeIndex,
      user: user ?? this.user,
      banned: banned ?? this.banned,
      lockEnabled: lockEnabled ?? this.lockEnabled,
      lockType: lockType ?? this.lockType,
      lockUnlocked: lockUnlocked ?? this.lockUnlocked,
      pendingInvite: pendingInvite ?? this.pendingInvite,
    );
  }
}

class AppStateController extends StateNotifier<AppState> {
  AppStateController() : super(const AppState()) {
    _active = true;
    _restore();
    // Аварийный выход со сплэша: если восстановление зависло (хранилище
    // молчит), принудительно открываем онбординг через 8 секунд.
    Timer(const Duration(seconds: 8), () {
      if (_active && !state.bootstrapped) {
        state = state.copyWith(bootstrapped: true);
      }
    });
  }

  bool _active = true;

  @override
  void dispose() {
    _active = false;
    super.dispose();
  }

  Future<void> _restore() async {
    var servers = const <ServerIdentity>[];
    try {
      final rawServers = await SecureStore.instance
          .loadServers()
          .timeout(const Duration(seconds: 5));
      servers = _normalizeServers(rawServers);
      if (servers != rawServers) {
        await SecureStore.instance.saveServers(servers);
      }
    } catch (e) {
      debugPrint('RESTORE loadServers FAIL: $e');
    }
    var settings = <String, dynamic>{};
    try {
      settings = HiveService.instance.settings;
    } catch (e) {
      debugPrint('RESTORE settings FAIL: $e');
    }
    final lockType = LockType.values.firstWhere(
      (t) => t.name == (settings['lockType'] as String? ?? 'none'),
      orElse: () => LockType.none,
    );
    // Глубокая ссылка приглашения, открытая до запуска приложения
    // (protoapp://join?code=...&server=...). Применяется на онбординг-экранах.
    var pendingInvite = '';
    try {
      final raw = await const MethodChannel('mesenger/deep_link')
          .invokeMethod<String>('getInitial');
      pendingInvite = raw ?? '';
    } catch (e) {
      debugPrint('DEEPLINK read FAIL: $e');
    }

    // Immediately set bootstrapped=true with empty state to avoid blocking UI
    state = AppState(
      bootstrapped: true,
      servers: servers,
      activeIndex: 0,
      user: null,
      banned: false,
      lockEnabled: settings['lockEnabled'] as bool? ?? false,
      lockType: lockType,
      pendingInvite: pendingInvite.isEmpty ? null : pendingInvite,
    );

    // Do network operations in background without blocking UI
    try {
      _restoreUserInBackground();
    } catch (e) {
      debugPrint('RESTORE BACKGROUND FAIL: $e');
    }
  }

  Future<void> _restoreUserInBackground() async {
    if (!_active) return;
    final servers = state.servers;
    if (servers.isEmpty) return;

    final server = servers[0];
    ApiClient.instance.bind(server);
    WebsocketService.instance.setCurrentServer(server);

    try {
      final me = await ApiClient.instance.fetchMe().timeout(const Duration(seconds: 10));
      if (_active) {
        state = state.copyWith(user: UserProfile.fromJson(me));
      }
      await _ensureWs(server);
      // Постоянный фоновый сервис: держит WS живым при свёрнутом приложении.
      // Стартуем и при авто-восстановлении сессии (не только при входе),
      // иначе после перезапуска приложения звонки/сообщения не доходят.
      unawaited(ForegroundService.instance.start());
      // Синхронизация публичного ключа E2EE при авто-восстановлении сессии:
      // раньше делалась только при явном входе (onAuthenticated). Если ключ
      // пересоздался (сбой хранилища), сервер хранил устаревший — собеседники
      // шифровали неверным ключом и не могли получить сообщения.
      await _syncPublicKey();
    } on ApiException catch (e) {
      debugPrint('RESTORE ApiException: ${e.message} banned=${e.banned}');
      if (!e.banned) {
        try {
          final login = await ApiClient.instance.login().timeout(const Duration(seconds: 10));
          final token = login['token'] as String;
          await SecureStore.instance.saveToken(server.domain, token);
          final updated = [...state.servers];
          updated[0] = ServerIdentity(
            domain: server.domain,
            name: server.name,
            scheme: server.scheme,
            port: server.port,
            token: token,
          );
          await SecureStore.instance.saveServers(updated);
          state = state.copyWith(
            servers: updated,
            user: UserProfile.fromJson(
              Map<String, dynamic>.from(login['user'] as Map),
            ),
          );
          await _ensureWs(updated[0]);
          unawaited(ForegroundService.instance.start());
        } catch (e) {
          debugPrint('RESTORE login error: $e');
        }
      }
    } catch (e) {
      debugPrint('RESTORE error: $e');
    }
  }

  /// Восстановление сессии должно подключать WebSocket так же, как и вход:
  /// иначе после перезапуска приложения WS мёртв и сообщения копятся в
  /// очереди отправки (доставка «в никуда»).
  Future<void> _ensureWs(ServerIdentity server) async {
    try {
      final token = server.token ?? await SecureStore.instance.readToken(server.domain);
      if (token == null || token.isEmpty) return;
      final serverWithToken = ServerIdentity(
        domain: server.domain,
        name: server.name,
        scheme: server.scheme,
        port: server.port,
        token: token,
      );
      WebsocketService.instance.disconnect();
      WebsocketService.instance.connect(serverWithToken);
    } catch (e) {
      debugPrint('RESTORE WS FAIL: $e');
    }
  }

  /// Выгрузка актуального публичного ключа E2EE на сервер. Тихий провал:
  /// если сервер недоступен — ничего страшного, синхронизация повторится
  /// при следующем запуске/входе.
  Future<void> _syncPublicKey() async {
    try {
      final pub = await E2eeService.instance.publicKeyB64();
      await ApiClient.instance.updateProfile({'public_key': pub}).timeout(
        const Duration(seconds: 10),
      );
    } catch (e) {
      debugPrint('SYNC PUBLIC KEY FAIL: $e');
    }
  }

  List<ServerIdentity> _normalizeServers(List<ServerIdentity> servers) {
    final result = servers.map((s) {
      final isLocal = s.domain == 'localhost' || RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(s.domain);
      if (isLocal && s.scheme == 'https' && s.port == null) {
        return ServerIdentity(
          domain: s.domain,
          name: s.name,
          scheme: 'http',
          port: 5050,
          token: s.token,
        );
      }
      return s;
    }).toList();
    return result;
  }

  Future<void> addServer(ServerIdentity server) async {
    final servers = [...state.servers, server];
    await SecureStore.instance.saveServers(servers);
    state = state.copyWith(servers: servers, activeIndex: servers.length - 1);
    _activate(servers.length - 1);
  }

  Future<void> switchServer(int index) async {
    if (index < 0 || index >= state.servers.length) return;
    state = state.copyWith(activeIndex: index);
    _activate(index);
  }

  Future<void> renameServer(int index, String name) async {
    if (index < 0 || index >= state.servers.length) return;
    final cur = state.servers[index];
    final servers = [...state.servers];
    servers[index] = ServerIdentity(
      domain: cur.domain,
      name: name,
      scheme: cur.scheme,
      port: cur.port,
      active: cur.active,
      token: cur.token,
      publicUrl: cur.publicUrl,
    );
    await SecureStore.instance.saveServers(servers);
    state = state.copyWith(servers: servers);
  }

  Future<void> removeServer(int index) async {
    if (state.servers.length <= 1) return;
    final servers = [...state.servers]..removeAt(index);
    await SecureStore.instance.saveServers(servers);
    var newIndex = state.activeIndex;
    if (index < state.activeIndex) {
      newIndex -= 1;
    } else if (index == state.activeIndex) {
      newIndex = 0;
    }
    state = state.copyWith(servers: servers, activeIndex: newIndex);
    _activate(newIndex);
  }

  void _activate(int index) {
    final server = state.servers[index];
    ApiClient.instance.bind(server);
    WebsocketService.instance.setCurrentServer(server);
    if (server.token != null && server.token!.isNotEmpty) {
      WebsocketService.instance.disconnect();
      WebsocketService.instance.connect(server);
    }
    _refreshUser();
  }

  Future<void> _refreshUser() async {
    try {
      final me = await ApiClient.instance.fetchMe().timeout(const Duration(seconds: 10));
      if (_active && state.activeServer != null) {
        state = state.copyWith(user: UserProfile.fromJson(me));
      }
    } on ApiException catch (e) {
      if (e.banned) state = state.copyWith(banned: true);
    } catch (_) {}
  }

  Future<void> onAuthenticated(String token, Map<String, dynamic> userJson) async {
    final servers = [...state.servers];
    final index = state.activeIndex;
    final server = servers[index];
    await SecureStore.instance.saveToken(server.domain, token);
    servers[index] = ServerIdentity(
      domain: server.domain,
      name: server.name,
      scheme: server.scheme,
      port: server.port,
      token: token,
    );
    await SecureStore.instance.saveServers(servers);
    state = state.copyWith(
      servers: servers,
      user: UserProfile.fromJson(userJson),
      banned: false,
    );
    _activate(index);
    // Постоянный фоновый сервис: держит WS живым при свёрнутом приложении,
    // чтобы сообщения и звонки доходили сразу, даже если приложение не открыто.
    unawaited(ForegroundService.instance.start());
    // Синхронизация публичного ключа E2EE: после восстановления/входа
    // ключ на сервере мог устареть или отсутствовать — обновляем, чтобы
    // собеседники могли шифровать входящие для этого аккаунта.
    try {
      final pub = await E2eeService.instance.publicKeyB64();
      await ApiClient.instance.updateProfile({'public_key': pub});
    } catch (_) {}
  }

  void updateUser(UserProfile user) {
    state = state.copyWith(user: user);
  }

  Future<void> setLock(LockType type) async {
    final settings = HiveService.instance.settings;
    settings['lockEnabled'] = type != LockType.none;
    settings['lockType'] = type.name;
    await HiveService.instance.saveSettings(settings);
    state = state.copyWith(lockEnabled: type != LockType.none, lockType: type, lockUnlocked: true);
  }

  void unlockSession() {
    state = state.copyWith(lockUnlocked: true);
  }

  void lockSession() {
    state = state.copyWith(lockUnlocked: false);
  }

  void markBanned() {
    state = state.copyWith(banned: true);
  }

  Future<void> logout() async {
    final server = state.activeServer;
    if (server != null) {
      await SecureStore.instance.clearToken(server.domain);
    }
    WebsocketService.instance.disconnect();
    unawaited(ForegroundService.instance.stop());
    state = state.copyWith(
      user: null,
      lockUnlocked: false,
      banned: false,
    );
  }
}

final appStateProvider =
    StateNotifierProvider<AppStateController, AppState>((ref) => AppStateController());