import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/features/onboarding/server_setup_screen.dart';
import 'package:mesenger/widgets/common.dart';

class OnboardingWelcomeScreen extends StatelessWidget {
  static const route = '/welcome';

  const OnboardingWelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              const Icon(Icons.public, size: 96, color: AppColors.accent),
              const SizedBox(height: 32),
              const Text(
                S.welcomeTitle,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                S.welcomeSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const Spacer(flex: 3),
              PrimaryButton(
                label: S.welcomeStart,
                onPressed: () => context.go(ServerSetupScreen.route),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
