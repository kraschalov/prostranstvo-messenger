import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/security/lock_service.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/features/home/home_shell.dart';
import 'package:mesenger/features/lock/pattern_lock.dart';
import 'package:mesenger/widgets/common.dart';

class LockSetupScreen extends ConsumerStatefulWidget {
  static const route = '/lock-setup';

  const LockSetupScreen({super.key});

  @override
  ConsumerState<LockSetupScreen> createState() => _LockSetupScreenState();
}

class _LockSetupScreenState extends ConsumerState<LockSetupScreen> {
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final available = await LockService.instance.biometricAvailable();
    if (mounted) setState(() => _biometricAvailable = available);
  }

  Future<void> _save(LockType type, String secret) async {
    await LockService.instance.saveSecret(type, secret);
    await ref.read(appStateProvider.notifier).setLock(type);
    if (mounted) context.go(HomeShell.route);
  }

  Future<void> _choosePin() async {
    final pin = await _promptSecret(S.lockEnterPin, digitsOnly: true);
    if (pin == null) return;
    final confirm = await _promptSecret(S.lockConfirm, digitsOnly: true);
    if (confirm == null) return;
    if (pin != confirm) {
      showAppSnack(context, S.lockNotMatch, error: true);
      return;
    }
    await _save(LockType.pin, pin);
  }

  Future<void> _choosePassword() async {
    final password = await _promptSecret(S.lockEnterPassword, digitsOnly: false);
    if (password == null) return;
    final confirm = await _promptSecret(S.lockConfirm, digitsOnly: false);
    if (confirm == null) return;
    if (password != confirm) {
      showAppSnack(context, S.lockNotMatch, error: true);
      return;
    }
    await _save(LockType.password, password);
  }

  Future<void> _choosePattern() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.lockDrawPattern),
        content: SizedBox(
          width: 280,
          height: 280,
          child: PatternLock(onCompleted: _onPatternFirst),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.cancel))],
      ),
    );
  }

  String? _firstPattern;

  void _onPatternFirst(String pattern) {
    _firstPattern = pattern;
    Navigator.pop(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.lockConfirmPattern),
        content: SizedBox(
          width: 280,
          height: 280,
          child: PatternLock(onCompleted: (second) async {
            Navigator.pop(ctx);
            if (second != _firstPattern) {
              showAppSnack(context, S.lockNotMatch, error: true);
              _firstPattern = null;
              return;
            }
            await _save(LockType.pattern, second);
          }),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.cancel))],
      ),
    );
  }

  Future<String?> _promptSecret(String title, {required bool digitsOnly}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: digitsOnly ? TextInputType.number : TextInputType.visiblePassword,
          maxLength: digitsOnly ? 4 : 64,
          decoration: InputDecoration(
            hintText: digitsOnly ? '1234' : '••••••••',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.pop(ctx, value);
            },
            child: const Text(S.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _setupBiometric() async {
    final ok = await LockService.instance.authenticateBiometric();
    if (!ok) {
      if (mounted) {
        showAppSnack(
          context,
          S.biometricFailed,
          error: true,
        );
      }
      return;
    }
    await _save(LockType.biometric, 'biometric');
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: S.lockSetupTitle,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            S.lockSetupSubtitle,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          if (_biometricAvailable) ...[
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text(S.lockBiometric),
              subtitle: const Text(S.lockBiometricDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: _setupBiometric,
            ),
            const Divider(),
          ],
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text(S.lockPin),
            trailing: const Icon(Icons.chevron_right),
            onTap: _choosePin,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.gesture),
            title: const Text(S.lockPattern),
            trailing: const Icon(Icons.chevron_right),
            onTap: _choosePattern,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text(S.lockPassword),
            trailing: const Icon(Icons.chevron_right),
            onTap: _choosePassword,
          ),
          const Divider(),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.go(HomeShell.route),
            child: const Text(S.lockSkip),
          ),
        ],
      ),
    );
  }
}
