import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:mesenger/features/chat/topics_screen.dart';
import 'package:mesenger/features/chat/topic_chat_screen.dart';

final chatsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return Stream<List<Map<String, dynamic>>>.multi((controller) {
    void emit() {
      // Гарантированная эмиссия: даже при ошибке чтения отдаём пустой
      // список, чтобы экран никогда не зависал на бесконечной загрузке.
      try {
        controller.add(_summaries());
      } catch (_) {
        controller.add(const <Map<String, dynamic>>[]);
      }
    }

    emit();
    try {
      final sub = HiveService.instance.chats.watch().listen((_) => emit());
      // Пины тем лежат в app-боксе — слушаем и его, иначе закрепление
      // не обновляет список до следующего сообщения.
      final sub2 = HiveService.instance.app.watch().listen((_) => emit());
      ref.onDispose(() {
        sub.cancel();
        sub2.cancel();
      });
    } catch (_) {
      // Бокс не открыт/не инициализирован — уже отдали пустой список выше.
    }
  });
});

List<Map<String, dynamic>> _summaries() {
  final result = <Map<String, dynamic>>[];
  // Темы по умолчанию скрыты из общих (только подраздел «Темы»),
  // кроме закреплённых пользователем.
  final pinnedTopics = HiveService.instance.pinnedTopicChats.toSet();
  try {
    final box = HiveService.instance.chats;
    for (final key in box.keys) {
      if (key is String &&
          key.startsWith('topic_') &&
          !pinnedTopics.contains(key)) {
        continue;
      }
      Map<String, dynamic> lastMap;
      try {
        final raw = box.get(key, defaultValue: const []);
        if (raw is List) {
          // Ищем последний элемент, который удаётся привести к Map —
          // старые записи могли содержать элементы иных типов.
          Map<String, dynamic>? found;
          for (final item in raw) {
            if (item is Map) {
              try {
                found = Map<String, dynamic>.from(item);
              } catch (_) {}
            }
          }
          if (found == null) continue;
          lastMap = found;
        } else if (raw is Map) {
          lastMap = Map<String, dynamic>.from(raw);
        } else {
          continue;
        }
      } catch (_) {
        // Сломанная запись — не можем извлечь ни одного сообщения.
        continue;
      }
      final rawTs = lastMap['createdAt'];
      int ts = 0;
      if (rawTs is num) {
        ts = rawTs.toInt();
      } else if (rawTs is String) {
        ts = int.tryParse(rawTs) ??
            DateTime.tryParse(rawTs)?.millisecondsSinceEpoch ??
            0;
      }
      final handle = lastMap['peerHandle']?.toString() ?? '';
      final outbound = lastMap['outbound'] == true;
      final unread = lastMap['unread'] == true && !outbound;
      var text = lastMap['deleted'] == true
          ? S.chatMessageDeleted
          : lastMap['payloadB64']?.toString() ?? '';
      if (outbound && text.isNotEmpty && text != S.chatMessageDeleted) {
        text = 'Вы: $text';
      }
      result.add({
        'chatId': key,
        'peerHandle': handle.isEmpty ? key : handle,
        'lastText': text,
        'lastTs': ts,
        'unread': unread,
      });
    }
    result.sort((a, b) => (b['lastTs'] as int).compareTo(a['lastTs'] as int));
  } catch (_) {}
  return result;
}

class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.chats),
        actions: [
          IconButton(
            tooltip: 'Диагностика',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (_) => const _DiagSheet(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              child: ListTile(
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      backgroundColor: AppColors.accentAlt
                          .withValues(alpha: 0.2),
                      child: const Icon(Icons.forum_outlined,
                          color: AppColors.accentAlt),
                    ),
                    if (HiveService.instance.anyTopicUnread)
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
                title: const Text('Темы'),
                subtitle: const Text(
                  'Групповые комнаты',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TopicsScreen(),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: chats.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const Center(child: Text(S.unknownError)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.chat_bubble_outline,
                title: S.emptyChats,
                hint: S.emptyChatsHint,
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final chat = list[i];
                final t = _chatTitle(chat['chatId'] as String);
                final unread = chat['unread'] == true;
                return ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      OnlineAvatar(
                        name: t.name,
                        photoPath: t.photoPath,
                      ),
                      if (unread)
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
                  title: Text(
                    t.name.isEmpty ? '—' : t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  subtitle: Text(
                    t.handle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    _time(chat['lastTs'] as int),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  onTap: () async {
                    final cid = chat['chatId'] as String;
                    if (cid.startsWith('topic_')) {
                      final tid =
                          int.tryParse(cid.substring('topic_'.length)) ?? 0;
                      var title = 'Тема';
                      try {
                        final t = await ApiClient.instance
                            .getTopic(tid);
                        title = ((t['topic'] as Map?)?['name']
                                ?.toString() ??
                            'Тема');
                      } catch (_) {}
                      if (context.mounted) {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TopicChatScreen(
                                topicId: tid, title: title),
                          ),
                        );
                      }
                      return;
                    }
                    context.go('/home/chat/$cid');
                  },
                );
              },
            );
          },
          ),
          ),
          ],
        ),
    );
  }

  /// Имя чата: дисплейное имя из контакта (если есть), иначе — ник.
  /// Возвращает пару {name, handle, photoPath}: заголовок — имя,
  /// под ним — ник мелким.
  ({String name, String handle, String photoPath}) _chatTitle(String chatId) {
    try {
      for (final c in HiveService.instance.contactsList) {
        if (c is Map && c['chatId'] == chatId) {
          final name = c['displayName']?.toString() ?? '';
          final handle = c['handle']?.toString() ?? '';
          final photoPath = c['photoPath']?.toString() ?? '';
          return (name: name, handle: handle, photoPath: photoPath);
        }
      }
    } catch (_) {}
    // Если контакт не известен — выводим чистый ник без «@» и домена.
    final raw = chatId.replaceFirst('dm_', '');
    return (name: '', handle: '@$raw', photoPath: '');
  }

  String _time(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}.${dt.month}';
  }
}

/// Компактная строка диагностики: состояние Hive, WebSocket и устройства.
/// Открывается по кнопке «i» в шапке раздела «Чаты».
class _DiagSheet extends ConsumerWidget {
  const _DiagSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = WebsocketService.instance;
    String chatCount = '?';
    String chatKeys = '';
    String chatSample = '';
    try {
      final box = HiveService.instance.chats;
      if (box.isOpen) {
        chatCount = box.length.toString();
        chatKeys = box.keys.take(3).join(',');
        for (final k in box.keys.take(1)) {
          final v = box.get(k);
          var inner = '$v';
          try {
            if (v is List && v.isNotEmpty) {
              final first = v.first;
              inner = 'len=${v.length}, first=${first.runtimeType}';
              if (first is Map) {
                inner += ', keys=${first.keys.take(6).toList()}';
              }
            }
          } catch (_) {}
          chatSample = '$k=${v.runtimeType} | $inner';
        }
      } else {
        chatCount = 'закрыт';
      }
    } catch (_) {}
    final info = 'Hive: чаты=$chatCount, err=${HiveService.instance.lastInitError.isEmpty ? '-' : HiveService.instance.lastInitError}'
        '\nключи: $chatKeys | $chatSample'
        '\nWS: ${ws.connected ? 'подключён' : 'нет'} | device: ${SecureStore.instance.deviceId.length > 12 ? SecureStore.instance.deviceId.substring(0, 12) : SecureStore.instance.deviceId}...';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Диагностика',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Копировать',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: info));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')),
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                info,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.greenAccent,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
