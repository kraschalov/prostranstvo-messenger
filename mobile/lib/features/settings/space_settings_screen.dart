import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';

/// Настройки пространства: редактирование названия/описания, список
/// участников, добавление по никнейму, удаление с полным блоком доступа.
class SpaceSettingsScreen extends ConsumerStatefulWidget {
  final Space space;

  const SpaceSettingsScreen({super.key, required this.space});

  @override
  ConsumerState<SpaceSettingsScreen> createState() => _SpaceSettingsScreenState();
}

class _SpaceSettingsScreenState extends ConsumerState<SpaceSettingsScreen> {
  late String _name;
  String _description = '';
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;
  bool _saving = false;
  late bool _isolated;
  late bool _visible;

  bool get _isOwner {
    final uid = ref.read(appStateProvider).user?.id;
    return uid == widget.space.ownerId || ref.read(appStateProvider).user?.isAdmin == true;
  }

  bool get _amMember {
    final uid = ref.read(appStateProvider).user?.id;
    return _members.any((m) => (m['id'] as num?)?.toInt() == uid);
  }

  @override
  void initState() {
    super.initState();
    _name = widget.space.name;
    _description = widget.space.description;
    _isolated = widget.space.isolated;
    _visible = widget.space.visible;
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final res = await ApiClient.instance.listSpaceMembers(widget.space.id);
      if (mounted) {
        setState(() {
          _members = (res['members'] as List)
              .map((m) => Map<String, dynamic>.from(m as Map))
              .toList();
          _loadingMembers = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  Future<void> _toggleSetting({bool? isolated, bool? visible}) async {
    setState(() {
      if (isolated != null) _isolated = isolated;
      if (visible != null) _visible = visible;
    });
    try {
      await ApiClient.instance.setSpaceSettings(
        widget.space.id,
        isolated: isolated,
        visible: visible,
      );
      if (mounted) showAppSnack(context, 'Сохранено');
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
      // Откатываем при ошибке.
      setState(() {
        if (isolated != null) _isolated = widget.space.isolated;
        if (visible != null) _visible = widget.space.visible;
      });
    } catch (_) {
      if (mounted) showAppSnack(context, S.unknownError, error: true);
    }
  }

  Future<void> _editInfo() async {
    final nameC = TextEditingController(text: _name);
    final descC = TextEditingController(text: _description);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Настройки пространства'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descC,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Описание'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.save)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameC.text.trim();
    if (name.isEmpty) {
      showAppSnack(context, S.required, error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.updateSpace(
        widget.space.id,
        name: name,
        description: descC.text.trim(),
      );
      if (mounted) {
        setState(() {
          _name = name;
          _description = descC.text.trim();
        });
        showAppSnack(context, S.save);
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMember() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить участника'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            labelText: 'Никнейм',
            hintText: '@username'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final username = c.text.trim().replaceFirst('@', '');
    if (username.isEmpty) return;
    try {
      await ApiClient.instance.addSpaceMember(widget.space.id, username);
      if (mounted) {
        showAppSnack(context, 'Участник добавлен');
        await _loadMembers();
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final name = member['display_name']?.toString().isNotEmpty == true
        ? member['display_name'].toString()
        : member['username']?.toString() ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить участника?'),
        content: Text(
          'Участник «$name» будет удалён из пространства и потеряет доступ '
          'к приложению (до ручного восстановления администратором).',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final uid = (member['id'] as num?)?.toInt() ?? 0;
    try {
      await ApiClient.instance.removeSpaceMember(widget.space.id, uid);
      if (mounted) {
        showAppSnack(context, 'Участник удалён, доступ заблокирован');
        await _loadMembers();
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: _name.isEmpty ? S.spacesTitle : _name,
      showBack: true,
      actions: [
        IconButton(
          tooltip: 'Изменить',
          icon: const Icon(Icons.edit_outlined),
          onPressed: _saving ? null : _editInfo,
        ),
        IconButton(
          tooltip: 'Добавить участника',
          icon: const Icon(Icons.person_add_alt),
          onPressed: _addMember,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Описание',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(_description.isEmpty ? '—' : _description),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Изолированное пространство'),
            subtitle: const Text(
              'Члены не создают свои пространства, не видят чужих и не могут открыться для других',
              style: TextStyle(fontSize: 12),
            ),
            value: _isolated,
            onChanged: _isOwner
                ? (v) => _toggleSetting(isolated: v)
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Видимость в «Общем»'),
            subtitle: const Text(
              'Показывать вас в общем пространстве другим пользователям',
              style: TextStyle(fontSize: 12),
            ),
            value: _visible,
            onChanged: (_isolated || !_amMember)
                ? null
                : (v) => _toggleSetting(visible: v),
          ),
          const SizedBox(height: 20),
          Text(
            'Участники (${_members.length})',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          if (_loadingMembers)
            const Center(child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ))
          else if (_members.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Участников пока нет', style: TextStyle(color: AppColors.textSecondary)),
            )
          else
            for (final m in _members)
              Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                    child: Text(
                      (m['display_name']?.toString().isNotEmpty == true
                              ? m['display_name'].toString()
                              : m['username']?.toString() ?? '?')
                          .substring(0, 1)
                          .toUpperCase(),
                    ),
                  ),
                  title: Text(m['display_name']?.toString().isNotEmpty == true
                      ? m['display_name'].toString()
                      : (m['username']?.toString() ?? '?')),
                  subtitle: Text('@${m['username']}'),
                  isThreeLine: false,
                  trailing: (m['id'] == widget.space.ownerId)
                      ? const Text(
                          'Владелец',
                          style: TextStyle(fontSize: 12, color: AppColors.accent),
                        )
                      : IconButton(
                          tooltip: 'Удалить',
                          icon: const Icon(Icons.person_off_outlined),
                          onPressed: () => _removeMember(m),
                        ),
                ),
              ),
        ],
      ),
    );
  }
}