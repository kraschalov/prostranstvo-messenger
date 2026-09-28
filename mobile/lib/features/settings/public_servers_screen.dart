import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/features/onboarding/server_setup_screen.dart';
import 'package:mesenger/widgets/common.dart';

/// Публичный каталог серверов (servers.json из репозитория).
/// Показывает ПСЕВДОНИМЫ, а не IP. Тап — скопировать адрес и перейти
/// к ручной настройке сервера.
class PublicServersScreen extends ConsumerStatefulWidget {
  static const route = '/public-servers';

  /// URL каталога в публичном репо. Заменить на реальный при публикации.
  static const catalogUrl =
      'https://raw.githubusercontent.com/kraschalov/prostranstvo-messenger/main/servers.json';

  const PublicServersScreen({super.key});

  @override
  ConsumerState<PublicServersScreen> createState() =>
      _PublicServersScreenState();
}

class _PublicServersScreenState extends ConsumerState<PublicServersScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _servers = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      )).get(PublicServersScreen.catalogUrl);
      final data = res.data;
      final list = (data is Map ? data['servers'] : data) as List? ?? const [];
      if (mounted) {
        setState(() {
          _servers =
              list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Каталог недоступен. Добавьте сервер вручную.';
        });
      }
    }
  }

  Future<void> _pick(Map<String, dynamic> s) async {
    final host = s['host']?.toString() ?? '';
    if (host.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: host));
    if (mounted) {
      showAppSnack(context, 'Адрес скопирован: $host');
      context.go(ServerSetupScreen.route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Серверы',
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _error != null
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        Text(_error!,
                            style: const TextStyle(
                                color: AppColors.textSecondary)),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _servers.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final s = _servers[i];
                        final fed = s['federation']?.toString() ?? 'open';
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.accent
                                  .withValues(alpha: 0.2),
                              child: Text(
                                (s['alias']?.toString().isNotEmpty == true
                                        ? s['alias'].toString()[0]
                                        : '?')
                                    .toUpperCase(),
                              ),
                            ),
                            title: Text(
                                s['alias']?.toString() ?? 'Без названия'),
                            subtitle: Text(
                              fed == 'open'
                                  ? 'Открыт для сопряжения'
                                  : 'Сопряжение: $fed',
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12),
                            ),
                            trailing: const Icon(Icons.add_link),
                            onTap: () => _pick(s),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
