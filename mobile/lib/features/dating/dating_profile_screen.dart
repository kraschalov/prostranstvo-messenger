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

class DatingProfileScreen extends ConsumerStatefulWidget {
  final String handle;

  const DatingProfileScreen({super.key, required this.handle});

  @override
  ConsumerState<DatingProfileScreen> createState() => _DatingProfileScreenState();
}

class _DatingProfileScreenState extends ConsumerState<DatingProfileScreen> {
  UserProfile? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await ApiClient.instance.searchByUsername(widget.handle);
      if (mounted) {
        setState(() {
          _profile = UserProfile.fromJson(result['profile']);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addToContacts(UserProfile profile) {
    HiveService.instance.addContact({
      'id': profile.id,
      'handle': profile.handle,
      'chatId': 'dm_${profile.id}',
      'server': profile.server,
      'publicKey': profile.publicKey,
      'displayName': profile.title,
      'age': profile.age,
      'city': profile.city,
      'bio': profile.bio,
    });
    showAppSnack(context, S.contactAdded);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return AppScaffold(
      title: S.datingTitle,
      showBack: true,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
              ? const Center(child: Text(S.contactNotFound))
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
                        radius: 44,
                        backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                        backgroundImage: profile.photoPath.isNotEmpty
                            ? null
                            : null,
                        child: profile.photoPath.isNotEmpty
                            ? ClipOval(
                                child: ServerImage(
                                  profile.photoPath,
                                  width: 88,
                                  height: 88,
                                  fit: BoxFit.cover,
                                  errorBuilder: Text(
                                    profile.title.isNotEmpty
                                        ? profile.title[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              )
                            : Text(
                                profile.title.isNotEmpty
                                    ? profile.title[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                    fontSize: 32, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        '${profile.title}, ${profile.age}',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        profile.handle,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _infoRow(Icons.location_city_outlined, S.city, profile.city),
                    _infoRow(Icons.wc_outlined, S.gender, _genderLabel(profile.gender)),
                    if (profile.goal.isNotEmpty)
                      _infoRow(Icons.track_changes_outlined, S.goal, profile.goal),
                    const SizedBox(height: 16),
                    if (profile.interests.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: profile.interests
                            .map((t) => StatusChip(text: t, color: AppColors.accentAlt))
                            .toList(),
                      ),
                    if (profile.bio.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(profile.bio, style: const TextStyle(height: 1.4)),
                    ],
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: PrimaryButton(
                            label: S.contactWrite,
                            onPressed: () => context.go('/home/chat/dm_${profile.id}'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          tooltip: S.contactAdd,
                          onPressed: () => _addToContacts(profile),
                          icon: const Icon(Icons.person_add_alt),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: AppColors.textSecondary)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String _genderLabel(String g) {
    switch (g) {
      case 'male':
        return S.genderMale;
      case 'female':
        return S.genderFemale;
      case 'other':
        return S.genderOther;
      default:
        return '—';
    }
  }
}
