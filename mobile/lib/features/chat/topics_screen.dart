import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'dart:async';
import 'package:mesenger/data/repositories/topic_repository.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/widgets/common.dart';

import 'topic_chat_screen.dart';

/// Темы: мои + открытые + создание (владелец сервера и семья).
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key});

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _mine = [];
  List<Map<String, dynamic>> _open = [];

  bool get _canCreate {
    final u = ref.read(appStateProvider).user;
    return u != null && (u.isAdmin || u.role == 'FAMILY_MEMBER');
  }

  StreamSubscription? _boxSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Живая точка непрочитанных: обновление прихода — пересчёт.
    _boxSub = HiveService.instance.chats.watch().listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _boxSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final mine = await ApiClient.instance.topicsMine();
      List<Map<String, dynamic>> open = [];
      try {
        final o = await ApiClient.instance.topicsOpen();
        open = ((o['topics'] as List? ?? const [])
                .map((e) => Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _mine = ((mine['topics'] as List? ?? const [])
                  .map((e) => Map<String, dynamic>.from(e as Map)))
              .toList();
          final mineIds = _mine.map((t) => t['id']).toSet();
          // Все нескрытые (закрытые тоже, просто без пометки): бэк уже
          // отфильтровал hidden/outside_only, вычитаем только свои.
          _open = open.where((t) => !mineIds.contains(t['id'])).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final name = TextEditingController();
    String privacy = 'closed';
    String visibility = 'inside';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Новая тема'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Название темы'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'closed', label: Text('Закрытая')),
                  ButtonSegment(
                      value: 'open', label: Text('Открытая')),
                ],
                selected: {privacy},
                onSelectionChanged: (s) => setD(() => privacy = s.first),
              ),
              const SizedBox(height: 8),
              const Text('Видимость', style: TextStyle(fontSize: 13)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'hidden', label: Text('Скрыта')),
                  ButtonSegment(value: 'inside', label: Text('Инсайд')),
                  ButtonSegment(
                      value: 'everywhere', label: Text('Везде')),
                  ButtonSegment(
                      value: 'outside_only', label: Text('Аутсайд')),
                ],
                selected: {visibility},
                onSelectionChanged: (s) =>
                    setD(() => visibility = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    try {
      final res = await ApiClient.instance.createTopic({
        'name': name.text.trim(),
        'privacy': privacy,
        'visibility': visibility,
      });
      final tid = (res['id'] as num?)?.toInt();
      if (tid != null) {
        // Сразу выпускаем ключ (пока только мы — раздавать некому).
        await TopicRepository.instance.issueKey(tid);
      }
      if (mounted) {
        showAppSnack(context, 'Тема создана');
        await _load();
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Не создалась: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Темы',
      showBack: true,
      actions: [
        if (_canCreate)
          IconButton(
            tooltip: 'Создать тему',
            icon: const Icon(Icons.add),
            onPressed: _create,
          ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Мои темы',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  const SizedBox(height: 8),
                  if (_mine.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Вы ни в одной теме',
                          style:
                              TextStyle(color: AppColors.textSecondary)),
                    )
                  else
                    for (final t in _mine) _topicTile(t),
                  const SizedBox(height: 16),
                  const Text('Темы',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  const SizedBox(height: 8),
                  if (_open.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Тем пока нет',
                          style:
                              TextStyle(color: AppColors.textSecondary)),
                    )
                  else
                    for (final t in _open) _topicTile(t, mine: false),
                ],
              ),
            ),
    );
  }

  Widget _topicTile(Map<String, dynamic> t, {bool mine = true}) {
    final tid = (t['id'] as num?)?.toInt() ?? 0;
    final name = t['name']?.toString() ?? 'Без названия';
    final privacy = t['privacy']?.toString() ?? 'closed';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              backgroundColor:
                  AppColors.accent.withValues(alpha: 0.2),
              child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?'),
            ),
            if (HiveService.instance
                .chatHasUnread('topic_$tid'))
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4CAF50),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        title: Text(name),
        subtitle: Text(
          privacy == 'closed' ? 'Закрытая' : 'Открытая',
          style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 12),
        ),
        onTap: () async {
          if (!mine) {
            final join = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(name),
                content: const Text(
                    'Открытая тема. Вступить и читать/писать?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Вступить')),
                ],
              ),
            );
            if (join != true || !mounted) return;
            try {
              await ApiClient.instance.joinTopic(tid);
              if (mounted) {
                showAppSnack(context, 'Вы в теме');
                await _load();
              }
            } catch (e) {
              if (mounted) {
                showAppSnack(context, 'Не вступилось: $e', error: true);
              }
              return;
            }
          }
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TopicChatScreen(topicId: tid, title: name),
            ),
          );
          if (mounted) _load();
        },
      ),
    );
  }
}
