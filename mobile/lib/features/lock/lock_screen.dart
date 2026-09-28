import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/security/lock_service.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/features/home/home_shell.dart';
import 'package:mesenger/features/lock/pattern_lock.dart';
import 'package:mesenger/widgets/common.dart';

class LockScreen extends ConsumerStatefulWidget {
  static const route = '/lock';

  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pinController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _error = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _pinController.addListener(_onPinChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUnlock());
  }

  @override
  void dispose() {
    _pinController.removeListener(_onPinChanged);
    _pinController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    if (_pinController.text.length == 4) {
      _verify(_pinController.text);
    }
  }

  Future<void> _autoUnlock() async {
    final type = ref.read(appStateProvider).lockType;
    if (type == LockType.biometric) {
      await _tryBiometric();
    }
  }

  Future<void> _tryBiometric() async {
    final ok = await LockService.instance.authenticateBiometric();
    if (ok && mounted) {
      _unlocked();
    }
  }

  void _unlocked() {
    ref.read(appStateProvider.notifier).unlockSession();
    context.go(HomeShell.route);
  }

  Future<void> _verify(String secret) async {
    if (secret.isEmpty) return;
    final ok = await LockService.instance.verify(secret);
    if (!mounted) return;
    if (ok) {
      _unlocked();
    } else {
      setState(() {
        _error = true;
        _attempts += 1;
      });
      _pinController.clear();
      _passwordController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = ref.watch(appStateProvider).lockType;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              const Icon(Icons.lock, size: 72, color: AppColors.accent),
              const SizedBox(height: 16),
              Text(
                S.lockTitle,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              if (_error) ...[
                const SizedBox(height: 8),
                const Text(S.lockWrong, style: TextStyle(color: AppColors.danger)),
              ],
              const Spacer(flex: 2),
              if (type == LockType.pin)
                TextField(
                  controller: _pinController,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 28, letterSpacing: 16),
                  decoration: const InputDecoration(
                    hintText: '••••',
                    counterText: '',
                  ),
                  onSubmitted: _verify,
                ),
              if (type == LockType.password)
                TextField(
                  controller: _passwordController,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: S.lockEnterPassword,
                  ),
                  onSubmitted: _verify,
                ),
              if (type == LockType.pin || type == LockType.password) ...[
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _verify(
                      type == LockType.pin
                          ? _pinController.text
                          : _passwordController.text,
                    ),
                    child: const Text(S.unlock),
                  ),
                ),
              ],
              if (type == LockType.pattern)
                SizedBox(
                  width: 300,
                  height: 300,
                  child: PatternLock(
                    onCompleted: _verify,
                  ),
                ),
              if (type == LockType.biometric)
                FilledButton.icon(
                  onPressed: _tryBiometric,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text(S.lockUseBiometric),
                ),
              if (_attempts >= 3)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    S.lockForgotHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              const Spacer(flex: 3),
              if (type != LockType.none)
                TextButton(
                  onPressed: () async {
                    final ok = await LockService.instance.authenticateBiometric();
                    if (ok) _unlocked();
                  },
                  child: const Text(S.lockUseBiometric),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
