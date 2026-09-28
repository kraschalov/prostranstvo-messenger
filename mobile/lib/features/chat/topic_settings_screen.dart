import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/security/topic_crypto.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/data/repositories/topic_repository.dart';
import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/widgets/common.dart';

/// Настройки темы: приватность, участники, права, инвайты.
/// Полный доступ — владелец темы и хозяин сервера.
class TopicSettingsScreen extends ConsumerStatefulWidget {
  final int topicId;
  final String title;

  const TopicSettingsScreen(
      {super.key, required this.topicId, required this.title});

  @override
  ConsumerState<TopicSettingsScreen> createState() =>
      _TopicSettingsScreenState();
}

class _TopicSettingsScreenState extends ConsumerState<TopicSettingsScreen> {
  bool _loading = true;
  Map<String, dynamic> _topic = {};
  List<Map<String, dynamic>> _members = [];
  final _invite = TextEditingController();

  bool get _isOwner {
    final u = ref.read(appStateProvider).user;
    if (u == null) return false;
    if (u.isAdmin) return true;
    return (_topic['owner_id'] as num?)?.toInt() == u.id;
  }

  /// Может звать: владелец либо (политика members + личный can_invite).
  bool get _canInvite {
    if (_isOwner) return true;
    final u = ref.read(appStateProvider).user;
    if (u == null) return false;
    if ((_topic['invite_policy']?.toString() ?? 'owner') != 'members') {
      return false;
    }
    for (final m in _members) {
      if ((m['id'] as num?)?.toInt() == u.id) {
        return (m['can_invite'] == 1);
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await ApiClient.instance.getTopic(widget.topicId);
      final m = await ApiClient.instance.topicMembers(widget.topicId);
      if (mounted) {
        setState(() {
          _topic = Map<String, dynamic>.from(t['topic'] as Map? ?? {});
          _members = ((m['members'] as List? ?? const [])
                  .map((e) => Map<String, dynamic>.from(e as Map)))
              .toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setField(String key, dynamic value) async {
    try {
      await ApiClient.instance.updateTopic(widget.topicId, {key: value});
      if (mounted) {
        setState(() => _topic[key] = value);
        showAppSnack(context, 'Сохранено');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _sendInvite() => _inviteUsername(_invite.text.trim());

  String _usernameOf(String handle) {
    var h = handle.trim();
    if (h.startsWith('@')) h = h.substring(1);
    final at = h.indexOf('@');
    return (at < 0 ? h : h.substring(0, at)).trim();
  }

  Future<void> _pickFromContacts() async {
    final contacts = HiveService.instance.contactsList
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
    final memberIds = _members
        .map((m) => (m['id'] as num?)?.toInt())
        .toSet();
    final candidates = contacts
        .where((c) => !memberIds.contains((c['id'] as num?)?.toInt()))
        .toList();
    if (!mounted) return;
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Позвать из близких'),
        content: SizedBox(
          width: double.maxFinite,
          child: candidates.isEmpty
              ? const Text('Некого звать — все уже в теме')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (ctx, i) {
                    final c = candidates[i];
                    return ListTile(
                      title: Text(
                          (c['displayName']?.toString().isNotEmpty == true)
                              ? c['displayName'].toString()
                              : (c['handle']?.toString() ?? '?')),
                      subtitle: Text(c['handle']?.toString() ?? ''),
                      onTap: () => Navigator.pop(ctx, c),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена')),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _inviteUsername(
        _usernameOf(picked['handle']?.toString() ?? ''));
  }

  Future<void> _inviteUsername(String name) async {
    if (name.isEmpty) return;
    try {
      await ApiClient.instance.inviteTopicMember(widget.topicId, name);
      // Сразу раздаём ключ новому участнику.
      final m = await ApiClient.instance.topicMembers(widget.topicId);
      final list = ((m['members'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map)))
          .toList();
      final stored = RoomKeyStore.get(widget.topicId);
      Map<String, dynamic>? target;
      for (final x in list) {
        if ((x['username']?.toString().toLowerCase() ??
                '') ==
            name.toLowerCase()) {
          target = x;
          break;
        }
      }
      if (stored != null && target != null) {
        await TopicRepository.instance.distributeKey(
          widget.topicId,
          stored['kid'] as String,
          stored['key'] as String,
          [target],
        );
      }
      _invite.clear();
      if (mounted) {
        showAppSnack(context, 'Приглашён');
        await _load();
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _toggleRight(
      Map<String, dynamic> m, String key, bool value) async {
    final uid = (m['id'] as num?)?.toInt();
    if (uid == null) return;
    try {
      await ApiClient.instance
          .setTopicRights(widget.topicId, uid, {key: value});
      if (mounted) {
        setState(() => m[key] = value ? 1 : 0);
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _kick(Map<String, dynamic> m) async {
    final uid = (m['id'] as num?)?.toInt();
    if (uid == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Исключить?'),
        content: Text(
            'Убрать ${m['display_name'] ?? m['username'] ?? ''} из темы? Ключ будет заменён.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Исключить')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await ApiClient.instance.kickTopicMember(widget.topicId, uid);
      // Ротация: ушедший со старым ключом прошлое читать сможет, будущее — нет.
      await TopicRepository.instance.rotateKey(widget.topicId);
      if (mounted) {
        showAppSnack(context, 'Исключён, ключ заменён');
        await _load();
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  @override
  void dispose() {
    _invite.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final privacy = _topic['privacy']?.toString() ?? 'closed';
    final visibility = _topic['visibility']?.toString() ?? 'hidden';
    final policy = _topic['invite_policy']?.toString() ?? 'owner';
    return AppScaffold(
      title: 'Настройки темы',
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                if (_isOwner) ...[
                  const Text('Приватность',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'closed', label: Text('Закрытая')),
                      ButtonSegment(
                          value: 'open', label: Text('Открытая')),
                    ],
                    selected: {privacy},
                    onSelectionChanged: (s) =>
                        _setField('privacy', s.first),
                  ),
                  const SizedBox(height: 12),
                  const Text('Видимость',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'hidden', label: Text('Скрыта')),
                      ButtonSegment(
                          value: 'inside',
                          label: Text('Свой сервер')),
                      ButtonSegment(
                          value: 'everywhere',
                          label: Text('Везде')),
                      ButtonSegment(
                          value: 'outside_only',
                          label: Text('Внешний')),
                    ],
                    selected: {visibility},
                    onSelectionChanged: (s) =>
                        _setField('visibility', s.first),
                  ),
                  const SizedBox(height: 12),

                  const SizedBox(height: 12),
                  const Text('Кто может приглашать',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'owner', label: Text('Владелец')),
                      ButtonSegment(
                          value: 'members',
                          label: Text('Участники')),
                    ],
                    selected: {policy},
                    onSelectionChanged: (s) =>
                        _setField('invite_policy', s.first),
                  ),
                ],
                if (_canInvite) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _invite,
                          decoration: const InputDecoration(
                            labelText: 'Ник для приглашения',
                            hintText: 'username',
                          ),
                          onSubmitted: (_) => _sendInvite(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Выбрать из близких',
                        icon: const Icon(Icons.contacts_outlined),
                        onPressed: _pickFromContacts,
                      ),
                      FilledButton.tonal(
                        onPressed: _sendInvite,
                        child: const Text('Позвать'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    const Expanded(
                      child: Text('Участники',
                          style:
                              TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    if (_isOwner)
                      TextButton.icon(
                        onPressed: () async {
                          try {
                            final stored = RoomKeyStore.get(widget.topicId);
                            final noPub = _members.where((m) => (m['public_key']?.toString() ?? '').isEmpty).map((m) => m['id']).toList();
                            await CallLog.instance.write('ROOMDLV start members=${_members.length} nopub=$noPub haskey=${stored != null} ws=${WebsocketService.instance.connected}');
                            int ok = 0;
                            if (stored == null) {
                              await TopicRepository.instance.issueKey(widget.topicId);
                              ok = -1;
                            } else {
                              ok = await TopicRepository.instance.distributeKey(
                                widget.topicId,
                                stored['kid'] as String,
                                stored['key'] as String,
                                _members,
                              );
                            }
                            await CallLog.instance.write('ROOMDLV done ok=$ok');
                            if (mounted) {
                              showAppSnack(context, ok == -1 ? 'Ключ выпущен и разослан' : 'Ключи разосланы: $ok из ${_members.length}');
                            }
                          } catch (e) {
                            await CallLog.instance.write('ROOMDLV FAIL: $e');
                            if (mounted) {
                              showAppSnack(context, 'Ошибка: $e', error: true);
                            }
                          }
                        },
                        icon: const Icon(Icons.key_outlined, size: 18),
                        label: const Text('Раздать ключи'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_members.isEmpty)
                  const Text('Пока никого нет',
                      style:
                          TextStyle(color: AppColors.textSecondary))
                else
                  for (final m in _members)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(
                            (m['display_name']?.toString().isNotEmpty ==
                                    true)
                                ? m['display_name'].toString()
                                : (m['username']?.toString() ?? '?')),
                        subtitle: Text(
                          (m['role']?.toString() ?? 'member') == 'owner'
                              ? 'Владелец'
                              : ((m['role']?.toString() ?? '') ==
                                      'moderator'
                                  ? 'Модератор'
                                  : 'Участник'),
                          style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12),
                        ),
                        trailing: _isOwner
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Может писать',
                                    icon: Icon(
                                      Icons.chat_bubble_outline,
                                      color: (m['can_post'] == 1)
                                          ? AppColors.accent
                                          : AppColors.textSecondary,
                                    ),
                                    onPressed: () => _toggleRight(m,
                                        'can_post', m['can_post'] != 1),
                                  ),
                                  IconButton(
                                    tooltip: 'Может приглашать',
                                    icon: Icon(
                                      Icons.person_add_alt,
                                      color: (m['can_invite'] == 1)
                                          ? AppColors.accent
                                          : AppColors.textSecondary,
                                    ),
                                    onPressed: () => _toggleRight(m,
                                        'can_invite',
                                        m['can_invite'] != 1),
                                  ),
                                  IconButton(
                                    tooltip: 'Исключить',
                                    icon: const Icon(
                                        Icons.person_remove_outlined,
                                        color: AppColors.danger),
                                    onPressed: () => _kick(m),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    ),
              ],
            ),
    );
  }
}
