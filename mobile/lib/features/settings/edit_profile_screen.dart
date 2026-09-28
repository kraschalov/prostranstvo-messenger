import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:mesenger/widgets/server_image.dart';

/// Редактирование профиля: основные поля + аватар + обложка (заставка).
class EditProfileScreen extends ConsumerStatefulWidget {
  static const route = '/profile/edit';

  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _displayName = TextEditingController();
  final _city = TextEditingController();
  final _interests = TextEditingController();
  final _bio = TextEditingController();
  String _gender = 'unknown';
  String _goal = '';
  DateTime? _birthDate;
  bool _datingSwitch = false;
  bool _federatedSearch = true;
  bool _crossServer = true;
  bool _loading = false;
  bool _uploading = false;
  String _avatarPath = '';
  String _coverPath = '';
  String _avatarRelPath = '';
  String _coverRelPath = '';
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final user = ref.read(appStateProvider).user;
    if (user != null) {
      _displayName.text = user.displayName;
      _city.text = user.city;
      _interests.text = user.interests.join(', ');
      _bio.text = user.bio;
      _gender = user.gender;
      _goal = user.goal;
      _datingSwitch = user.datingSwitch;
      _federatedSearch = user.federatedSearch;
      _crossServer = user.crossServerMessages;
      _avatarPath = user.photoPath;
      _coverPath = user.coverPath;
      _avatarRelPath = user.photoPath;
      _coverRelPath = user.coverPath;
      _avatarPath = _fullUrl(user.photoPath);
      _coverPath = _fullUrl(user.coverPath);
    }
  }

  /// Полный URL загруженного файла: относительный путь (например
  /// /uploads/u9_avatar_xxx.jpg) + baseUrl текущего сервера. URL из ответа
  /// загрузки не используем — он строится на сервере по его домену
  /// (localhost) и на телефоне не работает.
  String _fullUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = ApiClient.instance.baseUrl;
    if (base.isEmpty) return path;
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }

  @override
  void dispose() {
    _displayName.dispose();
    _city.dispose();
    _interests.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - 14, now.month, now.day),
      helpText: S.birthDate,
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  String _birthDateIso() {
    final d = _birthDate;
    if (d == null) return '';
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<Uint8List?> _pickImage() async {
    unawaited(CallLog.instance.write('PICK start'));
    try {
      // Основной способ — file_selector (официальный Flutter-плагин):
      // использует ACTION_GET_CONTENT и надёжно возвращает байты на
      // HyperOS/Android 16 (image_picker на POCO возвращает null из-за
      // launchMode=singleInstance MainActivity).
      try {
        const typeGroup = XTypeGroup(label: 'Изображения', extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif']);
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file != null) {
          final bytes = await file.readAsBytes();
          unawaited(CallLog.instance.write('PICK file_selector bytes=${bytes.length}'));
          return bytes;
        }
        unawaited(CallLog.instance.write('PICK file_selector -> null'));
      } catch (e, st) {
        unawaited(CallLog.instance.write('PICK file_selector FAIL: $e\n$st'));
      }

      // Fallback: image_picker (старый способ).
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final file = await _picker.pickImage(source: ImageSource.gallery);
          if (file != null) {
            final bytes = await file.readAsBytes();
            unawaited(CallLog.instance.write('PICK image_picker bytes=${bytes.length}'));
            return bytes;
          }
          unawaited(CallLog.instance.write('PICK image_picker attempt ${attempt + 1} -> null'));
        } catch (e, st) {
          unawaited(CallLog.instance.write('PICK image_picker FAIL: $e\n$st'));
        }
      }
      unawaited(CallLog.instance.write('PICK cancelled (all null)'));
      return null;
    } catch (e, st) {
      unawaited(CallLog.instance.write('PICK FAIL: $e\n$st'));
      debugPrint('PICK FAIL: $e\n$st');
      if (mounted) {
        showAppSnack(context, 'Не удалось прочитать выбранное фото: $e', error: true);
      }
      return null;
    }
  }

  Future<void> _setAvatar() async {
    final bytes = await _pickImage();
    if (bytes == null || !mounted) return;
    unawaited(CallLog.instance.write('UPLOAD avatar start bytes=${bytes.length}'));
    setState(() => _uploading = true);
    try {
      final res = await ApiClient.instance.uploadAvatar(bytes);
      unawaited(CallLog.instance.write('UPLOAD avatar OK -> ${res['photo_path']}'));
      if (mounted) {
        final rel = res['photo_path']?.toString() ?? '';
        setState(() {
          _avatarRelPath = rel;
          _avatarPath = _fullUrl(rel);
        });
      }
    } on ApiException catch (e) {
      unawaited(CallLog.instance.write('UPLOAD avatar API FAIL: ${e.message}'));
      if (mounted) showAppSnack(context, e.message, error: true);
    } catch (e, st) {
      unawaited(CallLog.instance.write('UPLOAD avatar FAIL: $e\n$st'));
      debugPrint('AVATAR UPLOAD FAIL: $e\n$st');
      if (mounted) showAppSnack(context, 'Не удалось загрузить аватар: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _setCover() async {
    final bytes = await _pickImage();
    if (bytes == null || !mounted) return;
    unawaited(CallLog.instance.write('UPLOAD cover start bytes=${bytes.length}'));
    setState(() => _uploading = true);
    try {
      final res = await ApiClient.instance.uploadCover(bytes);
      unawaited(CallLog.instance.write('UPLOAD cover OK -> ${res['cover_path']}'));
      if (mounted) {
        final rel = res['cover_path']?.toString() ?? '';
        setState(() {
          _coverRelPath = rel;
          _coverPath = _fullUrl(rel);
        });
      }
    } on ApiException catch (e) {
      unawaited(CallLog.instance.write('UPLOAD cover API FAIL: ${e.message}'));
      if (mounted) showAppSnack(context, e.message, error: true);
    } catch (e, st) {
      unawaited(CallLog.instance.write('UPLOAD cover FAIL: $e\n$st'));
      debugPrint('COVER UPLOAD FAIL: $e\n$st');
      if (mounted) showAppSnack(context, 'Не удалось загрузить заставку: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final fields = <String, dynamic>{
        'display_name': _displayName.text,
        'gender': _gender,
        if (_birthDate != null) 'birth_date': _birthDateIso(),
        'city': _city.text,
        'goal': _goal,
        'interests': _interests.text
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList(),
        'bio': _bio.text,
        'photo_path': _avatarRelPath,
        'cover_path': _coverRelPath,
        'dating_switch': _datingSwitch,
        'federated_search': _federatedSearch,
        'cross_server_messages': _crossServer,
      };
      final result = await ApiClient.instance.updateProfile(fields);
      if (!mounted) return;
      ref.read(appStateProvider.notifier).updateUser(
            UserProfile.fromJson(result),
          );
      context.pop();
      showAppSnack(context, 'Профиль сохранён');
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnack(context, S.unknownError, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _photoField({
    required String title,
    required String current,
    required VoidCallback onPick,
  }) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: current.isNotEmpty
              ? ServerImage(
                  current,
                  width: 88,
                  height: 88,
                  fit: BoxFit.cover,
                  errorBuilder: _photoPlaceholder(),
                )
              : _photoPlaceholder(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: _uploading ? null : onPick,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Выбрать фото'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoPlaceholder() {
    return Container(
      width: 88,
      height: 88,
      color: Colors.black12,
      child: const Icon(Icons.person_outline, size: 40, color: Colors.grey),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Редактирование профиля',
      showBack: true,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Фото и имя видят другие участники в чатах и «Инсайдерах».',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _photoField(
            title: 'Аватар',
            current: _avatarPath,
            onPick: _setAvatar,
          ),
          const SizedBox(height: 14),
          _photoField(
            title: 'Заставка (обложка)',
            current: _coverPath,
            onPick: _setCover,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _displayName,
            decoration: const InputDecoration(
              labelText: S.displayName,
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _gender,
            decoration: const InputDecoration(labelText: S.gender),
            items: const [
              DropdownMenuItem(value: 'unknown', child: Text('Не указано')),
              DropdownMenuItem(value: 'male', child: Text(S.genderMale)),
              DropdownMenuItem(value: 'female', child: Text(S.genderFemale)),
              DropdownMenuItem(value: 'other', child: Text(S.genderOther)),
            ],
            onChanged: (v) => setState(() => _gender = v ?? 'unknown'),
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: _pickBirthDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: S.birthDate,
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              child: Text(
                _birthDate == null
                    ? 'Не указано'
                    : '${_birthDate!.day}.${_birthDate!.month}.${_birthDate!.year}',
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _city,
            decoration: const InputDecoration(
              labelText: S.city,
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _goal,
            decoration: const InputDecoration(labelText: S.goal),
            items: const [
              DropdownMenuItem(value: '', child: Text('Не указано')),
              DropdownMenuItem(value: 'Дружба', child: Text(S.goalFriendship)),
              DropdownMenuItem(value: 'Общение', child: Text(S.goalCommunication)),
              DropdownMenuItem(value: 'Отношения', child: Text(S.goalRelations)),
              DropdownMenuItem(value: 'Деловые', child: Text(S.goalBusiness)),
            ],
            onChanged: (v) => setState(() => _goal = v ?? ''),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _interests,
            decoration: const InputDecoration(
              labelText: S.interests,
              prefixIcon: Icon(Icons.interests_outlined),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _bio,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: S.bio,
              hintText: S.bioHint,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            S.privacyTitle,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(S.datingSwitch),
            subtitle: const Text(S.datingSwitchDesc),
            value: _datingSwitch,
            onChanged: (v) => setState(() => _datingSwitch = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(S.federatedSearch),
            subtitle: const Text(S.federatedSearchDesc),
            value: _federatedSearch,
            onChanged: (v) => setState(() => _federatedSearch = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(S.crossServerMessages),
            subtitle: const Text(S.crossServerMessagesDesc),
            value: _crossServer,
            onChanged: (v) => setState(() => _crossServer = v),
          ),
          const SizedBox(height: 24),
          PrimaryButton(
            label: 'Сохранить',
            loading: _loading,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
