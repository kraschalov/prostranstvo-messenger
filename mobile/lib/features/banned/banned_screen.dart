import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';

class BannedScreen extends ConsumerStatefulWidget {
  static const route = '/banned';

  const BannedScreen({super.key});

  @override
  ConsumerState<BannedScreen> createState() => _BannedScreenState();
}

class _BannedScreenState extends ConsumerState<BannedScreen> {
  final _message = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _sendAppeal() async {
    setState(() => _sending = true);
    try {
      await ApiClient.instance.submitAppeal(_message.text);
      if (mounted) {
        showAppSnack(context, S.settingsAppealSent);
        _message.clear();
      }
    } on ApiException catch (e) {
      if (mounted) {
        showAppSnack(
          context,
          e.status == 429 ? S.settingsAppealRateLimit : e.message,
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.gavel, size: 80, color: AppColors.danger),
              const SizedBox(height: 24),
              const Text(
                S.settingsBanned,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                S.settingsBannedHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const Spacer(),
              TextField(
                controller: _message,
                maxLines: 4,
                maxLength: 2000,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: S.settingsAppealHint,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: S.settingsAppealHint,
                loading: _sending,
                onPressed: _message.text.trim().length >= 10 ? _sendAppeal : null,
              ),
              const SizedBox(height: 16),
              const Text(
                S.settingsAppealRateLimit,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
