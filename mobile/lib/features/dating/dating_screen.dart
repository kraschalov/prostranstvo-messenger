import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:mesenger/widgets/server_image.dart';

class DatingScreen extends ConsumerStatefulWidget {
  const DatingScreen({super.key});

  @override
  ConsumerState<DatingScreen> createState() => _DatingScreenState();
}

class _DatingScreenState extends ConsumerState<DatingScreen> {
  final _city = TextEditingController();
  final _tags = TextEditingController();
  String _gender = '';
  RangeValues _ageRange = const RangeValues(18, 60);
  List<UserProfile> _results = [];
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshMe());
  }

  @override
  void dispose() {
    _city.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _refreshMe() async {
    try {
      final me = await ApiClient.instance.fetchMe();
      if (mounted) {
        ref.read(appStateProvider.notifier).updateUser(
              UserProfile.fromJson(me),
            );
      }
    } catch (_) {}
  }

  Future<void> _enableVisibility() async {
    setState(() => _loading = true);
    try {
      await ApiClient.instance.updateProfile({'dating_switch': true});
      await _refreshMe();
      if (mounted) showAppSnack(context, 'Видимость включена');
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search() async {
    final me = ref.read(appStateProvider).user;
    if (me == null || !me.datingSwitch) return;
    final filter = DatingFilter(
      gender: _gender.isEmpty ? null : _gender,
      ageMin: _ageRange.start.round(),
      ageMax: _ageRange.end.round(),
      city: _city.text.trim().isEmpty ? null : _city.text.trim(),
      tags: _tags.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
    );
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final result = await ApiClient.instance.datingSearch(filter.toJson());
      if (mounted) {
        setState(() {
          _results = (result['profiles'] as List)
              .map((p) => UserProfile.fromJson(Map<String, dynamic>.from(p as Map)))
              .toList();
        });
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(appStateProvider).user;
    final enabled = me?.datingSwitch ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.datingTitle),
        actions: [
          IconButton(
            tooltip: S.datingFilters,
            icon: const Icon(Icons.tune),
            onPressed: () => _showFilters(context),
          ),
        ],
      ),
      body: !enabled
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyState(
                    icon: Icons.toggle_off_outlined,
                    title: S.datingDisabledTitle,
                    hint: S.datingDisabledHint,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _loading ? null : _enableVisibility,
                    icon: const Icon(Icons.visibility),
                    label: const Text('Включить видимость'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _city,
                          decoration: const InputDecoration(
                            hintText: S.datingCity,
                            prefixIcon: Icon(Icons.location_city_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _tags,
                          decoration: const InputDecoration(
                            hintText: S.datingTags,
                            prefixIcon: Icon(Icons.interests_outlined),
                          ),
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
                            : const Icon(Icons.search),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _results.isEmpty
                      ? EmptyState(
                          icon: Icons.favorite_outline,
                          title: _searched ? S.datingEmpty : S.datingEmptyBackground,
                          hint: _searched ? S.datingEmptyHint : S.datingFilters,
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _results.length,
                          itemBuilder: (context, i) => _DatingCard(
                            profile: _results[i],
                            onTap: () => context.go(
                              '/home/dating-profile/${Uri.encodeComponent(_results[i].handle)}',
                            ),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  void _showFilters(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                S.datingFilters,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(S.gender),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _genderChip(ctx, '', 'Любой'),
                  _genderChip(ctx, 'male', S.genderMale),
                  _genderChip(ctx, 'female', S.genderFemale),
                ],
              ),
              const SizedBox(height: 16),
              Text('${S.datingAgeRange}: ${_ageRange.start.round()}–${_ageRange.end.round()}'),
              RangeSlider(
                values: _ageRange,
                min: 14,
                max: 100,
                divisions: 86,
                onChanged: (v) => setSheet(() => _ageRange = v),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _search();
                },
                child: const Text(S.ok),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _genderChip(BuildContext ctx, String value, String label) {
    final selected = _gender == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _gender = value),
    );
  }
}

class _DatingCard extends StatelessWidget {
  final UserProfile profile;
  final VoidCallback onTap;

  const _DatingCard({required this.profile, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ClipOval(
                child: profile.photoPath.isNotEmpty
                    ? ServerImage(
                        ApiClient.instance.photoUrl(profile.photoPath),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 56,
                        height: 56,
                        color: AppColors.accent.withValues(alpha: 0.2),
                        alignment: Alignment.center,
                        child: Text(
                          profile.title.isNotEmpty ? profile.title[0].toUpperCase() : '?',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${profile.title}, ${profile.age}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profile.city.isNotEmpty ? profile.city : '—',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    if (profile.interests.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: profile.interests
                            .take(4)
                            .map((t) => StatusChip(text: t, color: AppColors.accentAlt))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
