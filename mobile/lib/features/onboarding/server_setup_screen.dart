import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/data/models/server_identity.dart';
import 'package:mesenger/features/onboarding/invite_screen.dart';
import 'package:mesenger/widgets/common.dart';

class ServerSetupScreen extends ConsumerStatefulWidget {
  static const route = '/server';

  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final _domain = TextEditingController();
  final _name = TextEditingController();
  /// Домашний сервер семьи (белый IP). В публичной сборке
  /// заменится выбором из каталога.
  /// Публичная сборка: адрес не предзаполнен — выбери сервер
  /// из каталога (servers.json) или вбей вручную.
  static const kDefaultServer = '';

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _prefillFromDeepLink();
  }

  /// Если приложение открыто по глубокой ссылке приглашения
  /// (protoapp://join?code=...&server=host:port) — предзаполняем адрес
  /// сервера, чтобы новичок не вводил его вручную.
  void _prefillFromDeepLink() {
    final pending = ref.read(appStateProvider).pendingInvite;
    final server = _serverFromLink(pending);
    if (server != null && _domain.text.isEmpty) {
      _domain.text = server;
      return;
    }
    // Семейный дефолт: свой сервер уже вписан — новичку остаётся
    // только нажать «Подключиться» (вход по отпечатку, без инвайта
    // для известных устройств).
    if (_domain.text.isEmpty && kDefaultServer.isNotEmpty) {
      _domain.text = kDefaultServer;
    }
  }

  String? _serverFromLink(String? link) {
    if (link == null || link.isEmpty) return null;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'protoapp' || uri.host != 'join') return null;
    return uri.queryParameters['server'];
  }

  @override
  void dispose() {
    _domain.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final parsed = _parseAddress(_domain.text);
    if (parsed == null || parsed.host.isEmpty) {
      showAppSnack(context, S.required, error: true);
      return;
    }
    setState(() => _loading = true);
    try {
      final server = ServerIdentity(
        domain: parsed.host,
        name: _name.text.trim().isEmpty ? parsed.host : _name.text.trim(),
        scheme: parsed.scheme,
        port: parsed.port,
      );
      await ref.read(appStateProvider.notifier).addServer(server);
      if (mounted) {
        showAppSnack(context, S.serverConnected);
        context.go(InviteScreen.route);
      }
    } catch (e) {
      if (mounted) showAppSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ({String scheme, String host, int? port})? _parseAddress(String input) {
    var s = input.trim().toLowerCase();
    if (s.isEmpty) return null;

    var scheme = 'https';
    if (s.startsWith('http://')) {
      scheme = 'http';
      s = s.substring(7);
    } else if (s.startsWith('https://')) {
      scheme = 'https';
      s = s.substring(8);
    }

    s = s.split('/').first;

    String host = s;
    int? port;
    if (s.contains(':')) {
      final parts = s.split(':');
      if (parts.length == 2) {
        host = parts[0];
        port = int.tryParse(parts[1]);
      }
    }

    if (host.isEmpty) return null;
    final isLocal = _isIpOrLocalhost(host);
    if (scheme == 'https' && isLocal) {
      scheme = 'http';
    }
    if (isLocal && port == null) {
      port = 5050;
    }
    return (scheme: scheme, host: host, port: port);
  }

  bool _isIpOrLocalhost(String host) {
    if (host == 'localhost') return true;
    final ipPattern = RegExp(
      r'^(\d{1,3}\.){3}\d{1,3}$',
    );
    return ipPattern.hasMatch(host);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: S.serverTitle,
      showBack: true,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            TextField(
              controller: _domain,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Адрес сервера',
                hintText: S.serverHint,
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: S.serverName,
                hintText: S.serverNameHint,
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 32),
            PrimaryButton(
              label: S.serverConnect,
              loading: _loading,
              onPressed: _connect,
            ),
          ],
        ),
      ),
    );
  }
}
