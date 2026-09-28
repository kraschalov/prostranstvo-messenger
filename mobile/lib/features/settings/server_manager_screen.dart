import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/onboarding/server_setup_screen.dart';
import 'package:dio/dio.dart';
import 'package:mesenger/data/models/server_identity.dart';
import 'package:mesenger/features/settings/public_servers_screen.dart';
import 'package:mesenger/widgets/common.dart';

class ServerManagerScreen extends ConsumerStatefulWidget {
  const ServerManagerScreen({super.key});

  @override
  ConsumerState<ServerManagerScreen> createState() => _ServerManagerScreenState();
}

class _ServerManagerScreenState extends ConsumerState<ServerManagerScreen> {
  bool _loadingPeers = false;
  List<Map<String, dynamic>> _peers = [];
  Map<String, dynamic>? _dashboard;
  bool _isAdmin = false;
  String _fedMode = 'closed';
  final _srvName = TextEditingController();
  final _srvCity = TextEditingController();
  final _srvCountry = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAdminData());
  }

  Future<void> _loadAdminData() async {
    final user = ref.read(appStateProvider).user;
    if (user == null) return;
    final isAdmin = user.isAdmin;
    setState(() => _isAdmin = isAdmin);
    if (!isAdmin) return;
    setState(() => _loadingPeers = true);
    try {
      final peers = await ApiClient.instance.adminPeers();
      final dashboard = await ApiClient.instance.adminDashboard();
      String mode = 'closed';
      try {
        final m = await ApiClient.instance.federationMode();
        mode = m['mode']?.toString() ?? 'closed';
      } catch (_) {}
      try {
        final prof = await ApiClient.instance.serverProfile();
        _srvName.text = prof['name']?.toString() ?? '';
        _srvCity.text = prof['city']?.toString() ?? '';
        _srvCountry.text = prof['country']?.toString() ?? '';
      } catch (_) {}
      if (mounted) {
        setState(() {
          _peers = (peers['peers'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _dashboard = dashboard;
          _fedMode = mode;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingPeers = false);
    }
  }

  Future<void> _setFedMode(String mode) async {
    try {
      await ApiClient.instance.setFederationMode(mode);
      if (mounted) {
        setState(() => _fedMode = mode);
        showAppSnack(context, 'Режим федерации: $mode');
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    }
  }

  Future<void> _linkServer() async {
    final controller = TextEditingController();
    final domain = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.serverLinkTitle),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: S.serverLinkHint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim().replaceFirst(RegExp(r'^https?://'), '');
              Navigator.pop(ctx, value);
            },
            child: const Text(S.serverLink),
          ),
        ],
      ),
    );
    if (domain == null || domain.isEmpty) return;
    try {
      await ApiClient.instance.linkFederation(domain);
      if (mounted) {
        showAppSnack(context, S.serverLinked);
        await _loadAdminData();
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    }
  }

  @override
  void dispose() {
    _srvName.dispose();
    _srvCity.dispose();
    _srvCountry.dispose();
    super.dispose();
  }

  bool _isIpLike(String s) =>
      RegExp(r'^[\d.:]+(:\d+)?$').hasMatch(s);

  Future<void> _showServerCard(ServerIdentity server) async {
    // Визитку тянем напрямую с ЭТОГО сервера (эндпоинт публичный).
    Map<String, dynamic>? info;
    try {
      final res = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      )).get('${server.baseUrl}/api/server_info');
      if (res.data is Map) {
        info = Map<String, dynamic>.from(res.data as Map);
      }
    } catch (_) {}
    if (!mounted) return;
    final name = (info?['name'] as String? ?? '').isNotEmpty
        ? info!['name'] as String
        : server.name;
    final city = info?['city'] as String? ?? '';
    final country = info?['country'] as String? ?? '';
    final fed = info?['federation'] as String? ?? '';
    final place =
        [city, country].where((e) => e.isNotEmpty).join(', ');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (place.isNotEmpty) Text(place),
            if (fed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  fed == 'open'
                      ? 'Открыт для сопряжения'
                      : 'Сопряжение: $fed',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appStateProvider);
    final servers = app.servers;
    return AppScaffold(
      title: S.settingsServers,
      showBack: true,
      actions: [
        IconButton(
          tooltip: S.addServer,
          icon: const Icon(Icons.add),
          onPressed: () => context.go(ServerSetupScreen.route),
        ),
        IconButton(
          tooltip: 'Каталог серверов',
          icon: const Icon(Icons.public),
          onPressed: () => context.go(PublicServersScreen.route),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            S.servers,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          ...servers.asMap().entries.map((entry) {
            final i = entry.key;
            final server = entry.value;
            final active = i == app.activeIndex;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                onTap: () => _showServerCard(server),
                leading: ServerAvatar(name: server.name, active: active),
                title: Text(server.name),
                subtitle: _isIpLike(server.domain)
                    ? const Text('Нажмите, чтобы посмотреть карточку')
                    : Text(server.domain),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!active)
                      TextButton(
                        onPressed: () =>
                            ref.read(appStateProvider.notifier).switchServer(i),
                        child: const Text(S.serverSwitch),
                      ),
                    if (servers.length > 1)
                      IconButton(
                        tooltip: S.serverRemove,
                        icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                        onPressed: () async {
                          await ref.read(appStateProvider.notifier).removeServer(i);
                        },
                      ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 24),
          if (_isAdmin) ...[
            const Text(
              'Режим сопряжения',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'closed', label: Text('Закрыт')),
                ButtonSegment(value: 'allowlist', label: Text('По списку')),
                ButtonSegment(value: 'open', label: Text('Открыт')),
              ],
              selected: {_fedMode},
              onSelectionChanged: (s) => _setFedMode(s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _srvName,
              decoration: const InputDecoration(
                labelText: 'Название сервера',
                hintText: 'Как увидят в каталоге',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _srvCity,
              decoration: const InputDecoration(
                labelText: 'Город',
                hintText: 'Где стоит сервер',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _srvCountry,
              decoration: const InputDecoration(
                labelText: 'Страна',
                hintText: 'Страна сервера',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () async {
                  try {
                    await ApiClient.instance.setServerProfile(
                      name: _srvName.text.trim(),
                      city: _srvCity.text.trim(),
                      country: _srvCountry.text.trim(),
                    );
                    // Имя на сервере стало источником правды — подтягиваем
                    // локальное имя баннера, чтобы не путало.
                    final nm = _srvName.text.trim();
                    if (nm.isNotEmpty) {
                      await ref
                          .read(appStateProvider.notifier)
                          .renameServer(app.activeIndex, nm);
                    }
                    if (mounted) {
                      showAppSnack(context, 'Профиль сервера сохранён');
                    }
                  } on ApiException catch (e) {
                    if (mounted) {
                      showAppSnack(context, e.message, error: true);
                    }
                  }
                },
                child: const Text('Сохранить'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    S.serverFederationHint,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _linkServer,
                  icon: const Icon(Icons.link),
                  label: const Text(S.serverLink),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Обновления с GitHub',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      final st =
                          await ApiClient.instance.updatesStatus();
                      if (mounted) {
                        showAppSnack(
                          context,
                          st['ok'] == true
                              ? 'Текущий ${st['current_build']}, свежий ${st['latest_build']} ${st['latest_tag'] ?? ''}'
                              : 'Проверка: ${st['error'] ?? 'недоступно'}',
                        );
                      }
                    } on ApiException catch (e) {
                      if (mounted) {
                        showAppSnack(context, e.message, error: true);
                      }
                    }
                  },
                  child: const Text('Проверить'),
                ),
                FilledButton.tonal(
                  onPressed: () async {
                    try {
                      final r = await ApiClient.instance.updatesPull();
                      if (mounted) {
                        showAppSnack(
                          context,
                          r['pulled'] == true
                              ? 'Скачан build ${r['build']}, раздаётся'
                              : '${r['reason'] ?? r['error'] ?? 'готово'}',
                        );
                      }
                    } on ApiException catch (e) {
                      if (mounted) {
                        showAppSnack(context, e.message, error: true);
                      }
                    }
                  },
                  child: const Text('Скачать'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              S.serverPeers,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            if (_loadingPeers)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else if (_peers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  S.serverEmptyPeers,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ..._peers.map(
                (p) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(p['domain'] as String? ?? ''),
                  subtitle: Text(p['name'] as String? ?? ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.link_off, color: AppColors.danger),
                    onPressed: () async {
                      await ApiClient.instance.unlinkFederation(p['domain'] as String);
                      await _loadAdminData();
                    },
                  ),
                ),
              ),
            if (_dashboard != null) ...[
              const SizedBox(height: 24),
              const Text(
                S.settingsAdmin,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _statCard('Пользователи', '${_dashboard!['users'] ?? 0}'),
                  _statCard('Пространства', '${_dashboard!['spaces'] ?? 0}'),
                  _statCard('Серверы', '${_dashboard!['peers'] ?? 0}'),
                  _statCard('Онлайн', '${_dashboard!['online'] ?? 0}'),
                  _statCard('Апелляции', '${_dashboard!['pending_appeals'] ?? 0}'),
                ],
              ),
            ],
          ] else
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                S.serverFederationHint,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Card(
      child: Container(
        width: 104,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
