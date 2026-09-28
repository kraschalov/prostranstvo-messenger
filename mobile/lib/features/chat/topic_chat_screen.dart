import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/data/repositories/topic_repository.dart';
import 'package:mesenger/core/security/topic_crypto.dart';
import 'package:mesenger/widgets/common.dart';

import 'topic_settings_screen.dart';

/// Чат темы: история из Hive (topic_N), отправка ключом комнаты.
class TopicChatScreen extends ConsumerStatefulWidget {
  final int topicId;
  final String title;

  const TopicChatScreen(
      {super.key, required this.topicId, required this.title});

  @override
  ConsumerState<TopicChatScreen> createState() => _TopicChatScreenState();
}

class _TopicChatScreenState extends ConsumerState<TopicChatScreen> {
  final _input = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  bool _sending = false;
  bool _hasKey = true;
  bool _pinned = false;
  final Map<int, String> _names = {};
  int? _ownerId;

  String get _chatId => TopicRepository.chatIdFor(widget.topicId);

  @override
  void initState() {
    super.initState();
    _reload();
    _checkKey();
    _loadNames();
    HiveService.instance.markChatRead(_chatId);
    HiveService.instance.chats.watch().listen((_) {
      if (mounted) _reload();
    });
  }

  Future<void> _checkKey() async {
    final has = RoomKeyStore.get(widget.topicId) != null;
    int? owner;
    try {
      final t = await ApiClient.instance.getTopic(widget.topicId);
      owner = ((t['topic'] as Map?)?['owner_id'] as num?)?.toInt();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _hasKey = has;
        _ownerId = owner;
      });
    }
  }

  Future<void> _askKey() async {
    final owner = _ownerId;
    if (owner == null) return;
    try {
      await TopicRepository.instance.requestKey(widget.topicId, owner);
      if (mounted) {
        showAppSnack(context, 'Запрос отправлен владельцу');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _loadNames() async {
    try {
      final res = await ApiClient.instance.topicMembers(widget.topicId);
      final map = <int, String>{};
      for (final m in (res['members'] as List? ?? const [])) {
        final mm = Map<String, dynamic>.from(m as Map);
        final id = (mm['id'] as num?)?.toInt();
        final dn = mm['display_name']?.toString() ?? '';
        final un = mm['username']?.toString() ?? '';
        if (id != null) map[id] = dn.isNotEmpty ? dn : un;
      }
      if (mounted) setState(() => _names.addAll(map));
    } catch (_) {}
  }

  String _senderLabel(Map<String, dynamic> m) {
    final id = (m['senderId'] as num?)?.toInt();
    if (id != null && _names.containsKey(id)) return _names[id]!;
    final s = m['senderName']?.toString() ?? '';
    return s;
  }

  void _reload() {
    _pinned =
        HiveService.instance.pinnedTopicChats.contains(_chatId);
    final h = HiveService.instance.chatHistory(_chatId);
    setState(() {
      _messages = h
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await TopicRepository.instance.sendMessage(widget.topicId, text);
      _input.clear();
      _reload();
    } catch (e) {
      if (mounted) {
        showAppSnack(context, 'Не отправлено: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: _pinned ? 'Убрать из Чатов' : 'Закрепить в Чатах',
            icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () async {
              final next = !_pinned;
              await HiveService.instance
                  .setTopicPinned(_chatId, next);
              if (mounted) setState(() => _pinned = next);
            },
          ),
          IconButton(
            tooltip: 'Настройки темы',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TopicSettingsScreen(
                  topicId: widget.topicId,
                  title: widget.title,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('Пока тихо. Напишите первым!',
                        style: TextStyle(
                            color: AppColors.textSecondary)),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[_messages.length - 1 - i];
                      final out = m['outbound'] == true;
                      final text = m['payloadB64']?.toString() ?? '';
                      final senderName = _senderLabel(m);
                      final ts =
                          (m['createdAt'] as num?)?.toInt() ?? 0;
                      final time = ts > 0
                          ? TimeOfDay.fromDateTime(
                                  DateTime.fromMillisecondsSinceEpoch(ts))
                              .format(context)
                          : '';
                      return Align(
                        alignment: out
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: out
                                ? AppColors.accent.withValues(alpha: 0.85)
                                : AppColors.accent
                                    .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!out && senderName.isNotEmpty)
                                Text(
                                  senderName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: AppColors.accentAlt),
                                ),
                              Text(text),
                              if (time.isNotEmpty)
                                Text(
                                  time,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textSecondary),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (!_hasKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: FilledButton.tonalIcon(
                onPressed: _askKey,
                icon: const Icon(Icons.key_outlined),
                label: const Text('Нет ключа темы — запросить у владельца'),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Сообщение в тему…',
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.all(Radius.circular(20)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
