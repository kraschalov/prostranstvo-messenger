import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:mesenger/widgets/server_image.dart';
import 'package:mesenger/core/calls/call_service.dart';
import 'package:mesenger/features/call/call_screen.dart';
import 'package:permission_handler/permission_handler.dart';

class ContactProfileScreen extends ConsumerStatefulWidget {
  final String handle;

  const ContactProfileScreen({super.key, required this.handle});

  @override
  ConsumerState<ContactProfileScreen> createState() =>
      _ContactProfileScreenState();
}

class _ContactProfileScreenState extends ConsumerState<ContactProfileScreen> {
  UserProfile? _profile;
  bool _loading = true;
  bool _isAdded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Пробуем найти контакт локально, чтобы взять id и handle.
      int? cid;
      Map<String, dynamic>? contact;
      for (final c in HiveService.instance.contactsList) {
        if (c is Map && c['handle'] == widget.handle) {
          contact = Map<String, dynamic>.from(c);
          cid = (c['id'] as num?)?.toInt();
          break;
        }
      }
      UserProfile profile;
      if (cid != null && cid > 0) {
        final res = await ApiClient.instance.fetchProfileById(cid);
        profile = UserProfile.fromJson(res);
      } else {
        final res =
            await ApiClient.instance.searchByUsername(widget.handle);
        profile = UserProfile.fromJson(res['profile']);
      }
      if (contact != null && cid != null) {
        // Обновляем локальный контакт (ключ, имя) из серверного профиля.
        await HiveService.instance.updateContact({
          'id': cid,
          'chatId': 'dm_$cid',
          'handle': profile.handle,
          'displayName': profile.title,
          'publicKey': profile.publicKey,
          'server': profile.server,
          'photo_path': profile.photoPath,
          'cover_path': profile.coverPath,
        });
      }
      final added = HiveService.instance.contactsList.any(
          (c) => c is Map && (c['id'] as num?)?.toInt() == profile.id);
      if (mounted) {
        setState(() {
          _profile = profile;
          _loading = false;
          _isAdded = added;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleContact() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      if (_isAdded) {
        await HiveService.instance.removeContact(profile.id);
      } else {
        await HiveService.instance.addContact({
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
        });
      }
      if (mounted) {
        setState(() => _isAdded = !_isAdded);
        showAppSnack(
            context, _isAdded ? S.contactAdded : 'Удалён из близких');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _startCall({required bool video}) async {
    final profile = _profile;
    if (profile == null) return;
    final mic = await Permission.microphone.request();
    final cam =
        video ? await Permission.camera.request() : PermissionStatus.granted;
    if (!mic.isGranted || (video && !cam.isGranted)) {
      if (mounted) {
        showAppSnack(context, 'Нет доступа к микрофону/камере', error: true);
      }
      return;
    }
    try {
      final session =
          await CallService.instance.startCall(profile, video: video);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CallScreen(session: session),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnack(context, 'Не удалось начать звонок', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return AppScaffold(
      title: S.contacts,
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
              ? const Center(child: Text('Контакт не найден'))
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (profile.coverPath.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ServerImage(
                          profile.coverPath,
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: const SizedBox(height: 160),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    Center(
                      child: CircleAvatar(
                        radius: 40,
                        backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                        child: profile.photoPath.isNotEmpty
                            ? ClipOval(
                                child: ServerImage(
                                  profile.photoPath,
                                  width: 80,
                                  height: 80,
                                  fit: BoxFit.cover,
                                  errorBuilder: Text(
                                    profile.title.isNotEmpty
                                        ? profile.title[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              )
                            : Text(
                                profile.title.isNotEmpty
                                    ? profile.title[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                    fontSize: 28, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(profile.title,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        profile.handle,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (profile.age > 0)
                      Text('${S.age}: ${profile.age}',
                          style: const TextStyle(color: AppColors.textSecondary)),
                    if (profile.city.isNotEmpty)
                      Text('${S.city}: ${profile.city}',
                          style: const TextStyle(color: AppColors.textSecondary)),
                    if (profile.bio.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(profile.bio, textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Позвонить',
                          icon: const Icon(Icons.call),
                          onPressed: () => _startCall(video: false),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Видеозвонок',
                          icon: const Icon(Icons.videocam),
                          onPressed: () => _startCall(video: true),
                        ),
                        IconButton.filledTonal(
                          tooltip: S.contactWrite,
                          icon: const Icon(Icons.chat_bubble_outline),
                          onPressed: () =>
                              context.go('/home/chat/dm_${profile.id}'),
                        ),
                        IconButton.filledTonal(
                          tooltip: _isAdded
                              ? 'Удалить из близких'
                              : 'Добавить в близкие',
                          icon: Icon(
                            _isAdded
                                ? Icons.person_remove
                                : Icons.person_add_alt,
                          ),
                          onPressed: _toggleContact,
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}
