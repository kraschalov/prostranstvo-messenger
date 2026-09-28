import 'package:flutter/material.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/server_image.dart';

class AppScaffold extends StatelessWidget {
  final String? title;
  final Widget body;
  final List<Widget>? actions;
  final bool showBack;

  const AppScaffold({
    super.key,
    this.title,
    required this.body,
    this.actions,
    this.showBack = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: title == null
          ? null
          : AppBar(
              title: Text(title!),
              leading: showBack
                  ? BackButton(onPressed: () => Navigator.of(context).maybePop())
                  : null,
              actions: actions,
            ),
      body: body,
    );
  }
}

class StatusChip extends StatelessWidget {
  final String text;
  final Color color;

  const StatusChip({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class ServerAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool active;

  const ServerAvatar({super.key, required this.name, this.size = 44, this.active = false});

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.surfaceAlt,
        shape: BoxShape.circle,
        border: active ? null : Border.all(color: AppColors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: active ? Colors.white : AppColors.textSecondary,
          fontSize: size * 0.42,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Аватар пользователя с индикатором «онлайн» (зелёная точка снизу).
/// online == null — статус неизвестен (точка не показывается).
class OnlineAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool? online;
  final String? photoPath;

  const OnlineAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.online,
    this.photoPath,
  });

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final hasPhoto = photoPath != null && photoPath!.isNotEmpty;
    final avatarUrl = hasPhoto ? ApiClient.instance.photoUrl(photoPath!) : null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.border),
          ),
          alignment: Alignment.center,
          child: hasPhoto
              ? ServerImage(avatarUrl!, width: size, height: size, fit: BoxFit.cover)
              : Text(
                  letter,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: size * 0.42,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
        if (online == true)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: size * 0.28,
              height: size * 0.28,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;

  const EmptyState({super.key, required this.icon, required this.title, this.hint});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const PrimaryButton({super.key, required this.label, this.onPressed, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          : Text(label),
    );
  }
}

void showAppSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : null,
      ),
    );
}
