import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/home/home_shell.dart';
import 'package:mesenger/features/onboarding/profile_setup_screen.dart';
import 'package:mesenger/widgets/common.dart';

class InviteScreen extends ConsumerStatefulWidget {
  static const route = '/invite';

  const InviteScreen({super.key});

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final _code = TextEditingController();
  final _recovery = TextEditingController();
  bool _loading = false;
  bool _recovering = false;
  bool _showRecovery = false;

  @override
  void initState() {
    super.initState();
    _prefillFromDeepLink();
  }

  /// Если приложение открыто по глубокой ссылке приглашения
  /// (protoapp://join?code=...&server=...) — подставляем код автоматически.
  void _prefillFromDeepLink() {
    final pending = ref.read(appStateProvider).pendingInvite;
    if (pending == null || pending.isEmpty) return;
    final uri = Uri.tryParse(pending);
    if (uri == null || uri.scheme != 'protoapp' || uri.host != 'join') return;
    final code = uri.queryParameters['code'];
    if (code != null && code.isNotEmpty) {
      _code.text = code.toUpperCase();
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final code = _code.text.trim().toUpperCase();
    if (code.isEmpty) {
      showAppSnack(context, S.required, error: true);
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await ApiClient.instance.validateInvite(code);
      if (!mounted) return;
      await _onAuthSuccess(result);
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.banned) {
        ref.read(appStateProvider.notifier).markBanned();
        return;
      }
      if (e.status == 404) {
        final recovered = await _tryRecover(code);
        if (!mounted) return;
        if (recovered) return;
      }
      showAppSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnack(context, S.unknownError, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Если код не оказался кодом приглашения — пробуем восстановление.
  Future<bool> _tryRecover(String code) async {
    try {
      final result = await ApiClient.instance.recover(code);
      if (!mounted) return false;
      await _onAuthSuccess(result, recoveryInput: code);
      return true;
    } on ApiException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _onAuthSuccess(Map<String, dynamic> result, {String? recoveryInput}) async {
    final recoveryCode = result['recovery_code'] as String? ?? recoveryInput;
    if (recoveryCode != null && recoveryCode.isNotEmpty) {
      final settings = HiveService.instance.settings;
      settings['recovery_code'] = recoveryCode;
      await HiveService.instance.saveSettings(settings);
    }
    await ref.read(appStateProvider.notifier).onAuthenticated(
          result['token'] as String,
          Map<String, dynamic>.from(result['user'] as Map),
        );
    if (!mounted) return;
    if (_isNewAccount(result)) {
      context.go(ProfileSetupScreen.route);
    } else {
      context.go(HomeShell.route);
    }
  }

  bool _isNewAccount(Map<String, dynamic> result) =>
      result['recovery_code'] != null;

  Future<void> _recover() async {
    final code = _recovery.text.trim().toUpperCase();
    if (code.isEmpty) {
      showAppSnack(context, S.required, error: true);
      return;
    }
    setState(() => _recovering = true);
    try {
      final result = await ApiClient.instance.recover(code);
      if (!mounted) return;
      await _onAuthSuccess(result, recoveryInput: code);
      if (!mounted) return;
      context.go(HomeShell.route);
    } on ApiException catch (e) {
      if (mounted) showAppSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showAppSnack(context, S.unknownError, error: true);
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: S.inviteTitle,
      showBack: true,
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          Text(
            'Доступ к серверу выдаётся только по одноразовому коду приглашения.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Код приглашения',
              hintText: S.inviteHint,
              prefixIcon: Icon(Icons.confirmation_number_outlined),
            ),
          ),
          const SizedBox(height: 24),
          PrimaryButton(
            label: S.inviteActivate,
            loading: _loading,
            onPressed: _activate,
          ),
          const SizedBox(height: 24),
          const Divider(),
          TextButton(
            onPressed: () => setState(() => _showRecovery = !_showRecovery),
            child: Text(
              _showRecovery
                  ? 'Скрыть восстановление доступа'
                  : 'Восстановить доступ по коду восстановления',
            ),
          ),
          if (_showRecovery) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _recovery,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Код восстановления',
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                prefixIcon: Icon(Icons.restore),
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Восстановить',
              loading: _recovering,
              onPressed: _recover,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await SecureStore.instance.resetDeviceId();
                if (context.mounted) {
                  showAppSnack(context,
                      'ID устройства сброшен. Вводите код восстановления.');
                }
              },
              child: const Text(
                'Клонированный телефон? Сбросить ID устройства',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
