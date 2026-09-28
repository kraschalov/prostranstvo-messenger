import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class SpacesScreen extends ConsumerStatefulWidget {
  const SpacesScreen({super.key});

  @override
  ConsumerState<SpacesScreen> createState() => _SpacesScreenState();
}

class _SpacesScreenState extends ConsumerState<SpacesScreen> {
  List<Space> _spaces = [];
  bool _loading = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await ApiClient.instance.listSpaces();
      if (mounted) {
        setState(() {
          _spaces = (result['spaces'] as List)
              .map((s) => Space.fromJson(Map<String, dynamic>.from(s as Map)))
              .toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createSpace() async {
    final name = TextEditingController();
    final description = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.spacesCreate),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: S.spacesName),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              decoration: const InputDecoration(labelText: S.spacesDescription),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.create)),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    setState(() => _creating = true);
    try {
      await ApiClient.instance.createSpace(name.text.trim(), description.text.trim());
      if (mounted) {
        showAppSnack(context, S.spacesCreated);
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _createInvite(Space space, bool isAdmin) async {
    var role = 'STANDARD_USER';
    final roleOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text(S.spacesInvite),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: const Text(S.spacesStandardRole),
                value: 'STANDARD_USER',
                groupValue: role,
                onChanged: (v) => setSheet(() => role = v!),
              ),
              if (isAdmin)
                RadioListTile<String>(
                  title: const Text(S.spacesFamilyRole),
                  value: 'FAMILY_MEMBER',
                  groupValue: role,
                  onChanged: (v) => setSheet(() => role = v!),
                ),
              const SizedBox(height: 8),
              const Text(
                S.spacesFamilyHint,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.ok)),
          ],
        ),
      ),
    );
    if (roleOk != true) return;
    try {
      final result = await ApiClient.instance.createInvite(space.id, role);
      if (!mounted) return;
      final code = result['code'] as String;
      final activeServer = ref.read(appStateProvider).activeServer;
      final base = activeServer?.baseUrl ?? ApiClient.instance.baseUrl;
      final inviteUrl = '$base/i/$code';
      final text = 'Приглашение в «${space.name}» от ${_inviterName()}.\n'
          'Скачай приложение «Пространство»: $inviteUrl\n'
          'Код приглашения: $code';
      await _showInviteDialog(code, inviteUrl, text, role);
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    }
  }

  String _inviterName() {
    final u = ref.read(appStateProvider).user;
    final name = u?.displayName ?? '';
    return name.isNotEmpty ? name : (u?.username ?? '');
  }

  Future<void> _showInviteDialog(
    String code,
    String inviteUrl,
    String text,
    String role,
  ) async {
    var qrVisible = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text(S.spacesInviteCode),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${S.spacesInviteRole}: ${role == 'FAMILY_MEMBER' ? S.spacesFamilyRole : S.spacesStandardRole}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ссылка для скачивания приложения:',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 4),
              SelectableText(
                inviteUrl,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                ),
              ),
              const SizedBox(height: 16),
              if (qrVisible) ...[
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: inviteUrl,
                      version: QrVersions.auto,
                      size: 200,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'QR-код',
                    icon: Icon(
                      qrVisible ? Icons.qr_code_2 : Icons.qr_code,
                    ),
                    onPressed: () => setDlg(() => qrVisible = !qrVisible),
                  ),
                  IconButton(
                    tooltip: 'Поделиться',
                    icon: const Icon(Icons.share),
                    onPressed: () {
                      Navigator.pop(ctx);
                      SharePlus.instance.share(ShareParams(text: text));
                    },
                  ),
                  IconButton(
                    tooltip: 'Копировать ссылку',
                    icon: const Icon(Icons.link),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: inviteUrl));
                      if (mounted) showAppSnack(context, S.copied);
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.pop(ctx);
                showAppSnack(context, S.copied);
              },
              child: const Text(S.spacesCopyCode),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.close)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(appStateProvider).user;
    final canCreate = user?.isFamilyOrAdmin ?? false;
    return AppScaffold(
      title: S.spacesTitle,
      showBack: true,
      actions: [
        if (canCreate)
          IconButton(
            onPressed: _creating ? null : _createSpace,
            icon: const Icon(Icons.add),
            tooltip: S.spacesCreate,
          ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _spaces.isEmpty
              ? const EmptyState(
                  icon: Icons.dashboard_outlined,
                  title: S.spacesEmpty,
                  hint: S.spacesFamilyHint,
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _spaces.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final space = _spaces[i];
                    final isOwner = space.ownerId == (user?.id ?? -1) || user?.isAdmin == true;
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.accent.withValues(alpha: 0.2),
                          child: Text(space.name[0].toUpperCase()),
                        ),
                        title: Text(space.name),
                        subtitle: space.description.isEmpty ? null : Text(space.description),
                        trailing: isOwner
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Настройки пространства',
                                    icon: const Icon(Icons.settings_outlined),
                                    onPressed: () => context.go(
                                      '/home/spaces/${space.id}/settings?'
                                      'name=${Uri.encodeQueryComponent(space.name)}&'
                                      'description=${Uri.encodeQueryComponent(space.description)}&'
                                      'owner=${space.ownerId}',
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: S.spacesInvite,
                                    icon: const Icon(Icons.person_add_alt),
                                    onPressed: () => _createInvite(space, user?.isAdmin ?? false),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    );
                  },
                ),
    );
  }
}
