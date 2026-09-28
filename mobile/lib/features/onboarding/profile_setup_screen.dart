import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/security/e2ee_service.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/onboarding/lock_setup_screen.dart';
import 'package:mesenger/widgets/common.dart';

class ProfileSetupScreen extends ConsumerStatefulWidget {
  static const route = '/profile';

  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _nickname = TextEditingController();
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
  String? _recoveryCode;

  @override
  void initState() {
    super.initState();
    _recoveryCode = HiveService.instance.settings['recovery_code'] as String?;
  }

  @override
  void dispose() {
    _nickname.dispose();
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
      initialDate: DateTime(now.year - 25, now.month, now.day),
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

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      final publicKey = await E2eeService.instance.publicKeyB64();
      final fields = <String, dynamic>{
        'username': _nickname.text,
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
        'public_key': publicKey,
        'dating_switch': _datingSwitch,
        'federated_search': _federatedSearch,
        'cross_server_messages': _crossServer,
      };
      final result = await ApiClient.instance.updateProfile(fields);
      if (!mounted) return;
      ref.read(appStateProvider.notifier).updateUser(
            UserProfile.fromJson(result),
          );
      context.go(LockSetupScreen.route);
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnack(context, S.unknownError, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: S.profileSetupTitle,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            S.profileSetupSubtitle,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (_recoveryCode != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.emergency_outlined, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Код восстановления аккаунта',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Сохраните его: он позволит вернуть доступ к этому аккаунту, '
                      'если приложение будет переустановлено.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _recoveryCode!,
                      style: const TextStyle(fontSize: 18, letterSpacing: 1.5),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _recoveryCode!));
                        showAppSnack(context, S.copied);
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Скопировать'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _nickname,
            decoration: const InputDecoration(
              labelText: S.nickname,
              hintText: S.nicknameHint,
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 14),
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
            label: S.continueLabel,
            loading: _loading,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
