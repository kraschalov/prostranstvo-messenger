import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/features/onboarding/profile_setup_screen.dart';
import 'package:mesenger/widgets/common.dart';

class PermissionOnboardingScreen extends StatefulWidget {
  static const route = '/permissions';
  const PermissionOnboardingScreen({super.key});

  @override
  State<PermissionOnboardingScreen> createState() => _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState extends State<PermissionOnboardingScreen> {
  bool _loading = false;
  Map<Permission, PermissionStatus> _status = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final notif = await Permission.notification.status;
    final mic = await Permission.microphone.status;
    final cam = await Permission.camera.status;
    if (!mounted) return;
    setState(() {
      _status = {
        Permission.notification: notif,
        Permission.microphone: mic,
        Permission.camera: cam,
      };
    });
  }

  Future<void> _requestAll() async {
    setState(() => _loading = true);
    try {
      var notif = await Permission.notification.request();
      var mic = await Permission.microphone.request();
      var cam = await Permission.camera.request();
      if (notif.isPermanentlyDenied || mic.isPermanentlyDenied || cam.isPermanentlyDenied) {
        if (mounted) {
          showAppSnack(context, 'Разрешения отклонены навсегда — открой Настройки приложения', error: true);
        }
      }
      await _refresh();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _continue() {
    context.go(ProfileSetupScreen.route);
  }

  Widget _tile(IconData icon, String title, String subtitle, Permission perm) {
    final st = _status[perm];
    final granted = st == PermissionStatus.granted;
    final denied = st == PermissionStatus.permanentlyDenied || st == PermissionStatus.denied;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: granted ? AppColors.accent : null),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: Icon(
          granted ? Icons.check_circle : (denied ? Icons.cancel : Icons.help_outline),
          color: granted ? AppColors.accent : (denied ? Colors.redAccent : Colors.grey),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allGranted = _status.values.every((e) => e == PermissionStatus.granted);
    return AppScaffold(
      title: 'Разрешения',
      showBack: false,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Icon(Icons.shield_outlined, size: 64, color: AppColors.accent),
            const SizedBox(height: 16),
            const Text(
              'Для звонков, сообщений и уведомлений нужны разрешения.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 24),
            _tile(Icons.notifications_outlined, 'Уведомления', 'Входящие звонки и сообщения когда свёрнуто', Permission.notification),
            const SizedBox(height: 8),
            _tile(Icons.mic_outlined, 'Микрофон', 'Голосовые сообщения и звонки', Permission.microphone),
            const SizedBox(height: 8),
            _tile(Icons.videocam_outlined, 'Камера', 'Видео-звонки и фото', Permission.camera),
            const Spacer(),
            PrimaryButton(
              label: allGranted ? 'Разрешения выданы' : 'Выдать разрешения',
              loading: _loading,
              onPressed: allGranted ? _continue : _requestAll,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _continue,
              child: Text(allGranted ? 'Продолжить' : 'Пропустить'),
            ),
            const SizedBox(height: 8),
            Text(
              'Можно выдать позже в Настройках телефона → Приложения → Пространство → Разрешения',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}