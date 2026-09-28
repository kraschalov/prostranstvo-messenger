import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';

final contactsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return Stream<List<Map<String, dynamic>>>.multi((controller) {
    void emit() {
      try {
        final list = HiveService.instance.contactsList;
        final out = list
            .map((c) => Map<String, dynamic>.from(c as Map))
            .toList();
        controller.add(out);
      } catch (_) {
        controller.add(const <Map<String, dynamic>>[]);
      }
    }

    emit();
    try {
      final sub = HiveService.instance.contacts.watch().listen((_) => emit());
      ref.onDispose(sub.cancel);
    } catch (_) {}
  });
});

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _query = TextEditingController();
  UserProfile? _result;
  bool _loading = false;
  bool _showDebug = false;
  final Map<int, bool> _onlineById = {};
  Timer? _onlineTimer;

  bool get _onlineEnabled =>
      HiveService.instance.settings['show_online_status'] as bool? ?? true;

  @override
  void initState() {
    super.initState();
    _refreshOnline();
    // Опрашиваем онлайн-статус контактов каждые 30 секунд.
    _onlineTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshOnline());
  }

  Future<void> _refreshOnline() async {
    try {
      final list = HiveService.instance.contactsList;
      final ids = list
          .map((c) => (c is Map) ? c['id'] : null)
          .whereType<int>()
          .toList();
      for (final id in ids) {
        try {
          final profile = await ApiClient.instance.fetchProfileById(id);
          final online = profile['online'] == true;
          if (mounted) {
            setState(() => _onlineById[id] = online);
          }
          // Подтягиваем актуальное фото профиля в локальный контакт,
          // чтобы фото показывалось в кружке списка «Близкие» (после
          // обновления раздела). Делаем только если фото изменилось.
          final photo = profile['photo_path']?.toString() ?? '';
          final existing = list.cast<Map?>().firstWhere(
                (c) => c?['id'] == id,
                orElse: () => null,
              );
          final oldPhoto = existing?['photoPath']?.toString() ?? '';
          if (photo.isNotEmpty && photo != oldPhoto) {
            await HiveService.instance.updateContact({
              'id': id,
              'chatId': 'dm_$id',
              'photoPath': photo,
            });
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  bool _isContactAdded(UserProfile profile) {
    final contacts = HiveService.instance.contactsList;
    return contacts.any((c) => c['id'] == profile.id);
  }

  void _printDebugInfo() {
    final contacts = HiveService.instance.contactsList;
    debugPrint('=== CONTACTS DEBUG ===');
    debugPrint('Count: ${contacts.length}');
    for (final c in contacts) {
      debugPrint('  - ${c['handle']} (id: ${c['id']}, chatId: ${c['chatId']})');
    }
    debugPrint('======================');
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _loading = true);
    try {
      final result = await ApiClient.instance.searchByUsername(q);
      if (mounted) {
        setState(() => _result = UserProfile.fromJson(result['profile']));
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _result = null);
        showAppSnack(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addToContacts(UserProfile profile) {
    final contacts = HiveService.instance.contactsList;
    final exists = contacts.any((c) => c['id'] == profile.id);
    if (exists) {
      showAppSnack(context, 'Уже в контактах');
      return;
    }
    HiveService.instance.addContact({
      'id': profile.id,
      'handle': profile.handle,
      'chatId': 'dm_${profile.id}',
      'server': profile.server,
      'publicKey': profile.publicKey,
      'displayName': profile.title,
      'photoPath': profile.photoPath,
      'age': profile.age,
      'city': profile.city,
      'bio': profile.bio,
    }).then((_) {
      if (mounted) showAppSnack(context, S.contactAdded);
    }).catchError((e) {
      if (mounted) showAppSnack(context, 'Ошибка сохранения: $e', error: true);
    });
  }

  void _openChat(UserProfile profile) {
    final chatId = 'dm_${profile.id}';
    context.go('/home/chat/$chatId');
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.contactSearchTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Debug: печать контактов в консоль',
            onPressed: _printDebugInfo,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      hintText: S.contactSearchHint,
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _loading ? null : _search,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          if (_result != null)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(_result!.title),
                subtitle: Text(
                  _result!.handle,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                isThreeLine: false,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: S.contactWrite,
                      icon: const Icon(Icons.chat_bubble_outline),
                      onPressed: () => _openChat(_result!),
                    ),
                    if (!_isContactAdded(_result!))
                      IconButton(
                        tooltip: S.contactAdd,
                        icon: const Icon(Icons.person_add_alt),
                        onPressed: () => _addToContacts(_result!),
                      )
                    else
                      IconButton(
                        tooltip: 'Уже в контактах',
                        icon: const Icon(Icons.check_circle, color: AppColors.accentAlt),
                        onPressed: () {},
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Мои контакты (${contacts.valueOrNull?.length ?? 0})',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ),
          Expanded(
            child: contacts.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
              data: (list) {
                if (list.isEmpty) {
                  return const EmptyState(
                    icon: Icons.people_outline,
                    title: 'Контактов пока нет',
                    hint: S.contactSearchHint,
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final cid = c['id'] as int?;
                    return ListTile(
                      leading: OnlineAvatar(
                        name: c['displayName'] as String? ?? '',
                        online: _onlineEnabled ? _onlineById[cid] : null,
                        photoPath: c['photoPath'] as String? ?? '',
                      ),
                      title: Text(c['displayName'] as String? ?? ''),
                      subtitle: Text(c['handle'] as String? ?? ''),
                      onTap: () => context.go(
                        '/home/contact/${Uri.encodeComponent(c['handle'] as String? ?? '')}',
                      ),
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
}
