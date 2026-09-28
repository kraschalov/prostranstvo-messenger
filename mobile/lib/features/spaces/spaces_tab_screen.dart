import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/settings/space_settings_screen.dart';
import 'package:mesenger/features/spaces/open_spaces_screen.dart';
import 'package:mesenger/widgets/common.dart';

/// Вкладка «Пространства» (вместо бывших «Знакомства»/«Инсайдеры»).
/// Показывает карточки пространств пользователя + «Общее» + создание.
class SpacesTabScreen extends ConsumerStatefulWidget {
  const SpacesTabScreen({super.key});

  @override
  ConsumerState<SpacesTabScreen> createState() => _SpacesTabScreenState();
}

class _SpacesTabScreenState extends ConsumerState<SpacesTabScreen> {
  List<Space> _spaces = [];
  List<Space> _insiderSpaces = [];
  int _openCount = 0;
  bool _loading = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await ApiClient.instance.listMySpaces();
      final mine = (result['spaces'] as List)
          .map((s) => Space.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList();
      final mineIds = mine.map((s) => s.id).toSet();
      List<Space> others = [];
      int openCount = 0;
      try {
        final allRes = await ApiClient.instance.listSpaces();
        others = ((allRes['spaces'] as List)
                .map((s) => Space.fromJson(Map<String, dynamic>.from(s as Map)))
                .where((s) => !mineIds.contains(s.id)))
            .toList();
      } catch (_) {}
      try {
        final openRes = await ApiClient.instance.listOpenSpaces();
        openCount = ((openRes['spaces'] as List?) ?? const []).length;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _spaces = mine;
          _insiderSpaces = others;
          _openCount = openCount;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createSpace() async {
    final name = TextEditingController();
    final description = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Создать пространство'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Название'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              decoration: const InputDecoration(labelText: 'Описание'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    setState(() => _creating = true);
    try {
      await ApiClient.instance.createSpace(name.text.trim(), description.text.trim());
      if (mounted) {
        showAppSnack(context, 'Пространство создано');
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openSpace(Space space) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpaceSettingsScreen(space: space),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(appStateProvider).user;
    final canCreate = user?.isFamilyOrAdmin ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Пространства'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          if (canCreate)
            IconButton(
              tooltip: 'Создать пространство',
              icon: const Icon(Icons.add),
              onPressed: _creating ? null : _createSpace,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Открытые пространства — первым.
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.public,
                          color: AppColors.accentAlt),
                      title: const Text('Открытые пространства'),
                      subtitle: Text(
                        _openCount == 0
                            ? 'Пока нет'
                            : 'Пространств: $_openCount',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const OpenSpacesScreen(),
                          ),
                        );
                        if (mounted) _load();
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.people_outline,
                          color: AppColors.accent),
                      title: const Text('Инсайдеры'),
                      subtitle: const Text(
                        'Люди с включённой видимостью',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                      onTap: () => context.go('/home/insiders'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const SizedBox(height: 12),
                  Text(
                    'Мои пространства (${_spaces.length})',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  if (_spaces.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Пространств пока нет. Нажмите «+», чтобы создать.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  else
                    for (final space in _spaces)
                      Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                            child: Text(
                              space.name.isNotEmpty
                                  ? space.name[0].toUpperCase()
                                  : '?',
                            ),
                          ),
                          title: Text(space.name),
                          subtitle: Text(
                            space.description.isEmpty
                                ? (space.isolated ? 'Изолированное' : '—')
                                : space.description,
                          ),
                          trailing: space.isolated
                              ? const Icon(Icons.lock_outline,
                                  color: AppColors.accent, size: 18)
                              : null,
                          onTap: () => _openSpace(space),
                        ),
                      ),
                  if (user?.isAdmin == true) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Пространства инсайдеров (${_insiderSpaces.length})',
                      style:
                          const TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    if (_insiderSpaces.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Чужих пространств нет.',
                          style:
                              TextStyle(color: AppColors.textSecondary),
                        ),
                      )
                    else
                      for (final space in _insiderSpaces)
                        Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.accentAlt
                                  .withValues(alpha: 0.2),
                              child: Text(
                                space.name.isNotEmpty
                                    ? space.name[0].toUpperCase()
                                    : '?',
                              ),
                            ),
                            title: Text(space.name),
                            subtitle: Text(
                              space.description.isEmpty
                                  ? 'Инсайдерское'
                                  : space.description,
                            ),
                            trailing: const Icon(
                                Icons.admin_panel_settings_outlined,
                                color: AppColors.accentAlt,
                                size: 18),
                            onTap: () => _openSpace(space),
                          ),
                        ),
                  ],
                ],
              ),
            ),
    );
  }
}
