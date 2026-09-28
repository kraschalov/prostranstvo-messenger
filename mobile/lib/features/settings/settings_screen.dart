import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:cryptography/cryptography.dart';
import 'package:mesenger/widgets/server_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Готовые рингтоны (raw-ресурсы без расширения) с человекочитаемыми метками.
const _ringtoneOptions = <String, String>{
  'ringtone': 'Классический',
  'ring1': 'Мелодия 1',
  'ring2': 'Мелодия 2',
  'ring3': 'Мелодия 3',
  'ring4': 'Мелодия 4',
  'ring5': 'Мелодия 5',
  'ring6': 'Мелодия 6',
  'ring7': 'Мелодия 7',
  'ring8': 'Мелодия 8',
};

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {

/// SHA-256 отпечатка релизного ключа подписи. APK с чужой подписью
/// не ставится (защита от подмены в пути и троянских сборок).
// ignore: unused_field
static const _releaseCertSha256 =
    '0fa548a57e3b8d0ca8ba6494e911e342abb5888358dc3bf0b6f90e87d3dea387';
  bool _saving = false;
  bool _updating = false;
  MethodChannel channel = const MethodChannel('mesenger/incoming_ring');


  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appStateProvider);
    final user = app.user;
    final recoveryCode = HiveService.instance.settings['recovery_code'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: const Text(S.settings),
        actions: [
          IconButton(
            tooltip: S.settingsAdmin,
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => context.go('/home/servers'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (user != null) _profileHeader(user),
          _section(S.settingsSecurity, [
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text(S.settingsLock),
              subtitle: const Text(S.lockSetupSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/home/lock-settings'),
            ),
            _receiptsSwitch(),
            _onlineSwitch(),
          ]),
          _section('Звонки', [
            ListTile(
              leading: const Icon(Icons.ring_volume_outlined),
              title: const Text('Рингтон звонка'),
              subtitle: Text(_ringtoneLabel(_ringtoneName)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showRingtonePicker(),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Лог звонков (для отладки)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showCallLog(),
            ),
          ]),
          _section('Код восстановления аккаунта', [
            if (recoveryCode != null)
              ListTile(
                leading: const Icon(Icons.emergency_outlined),
                title: SelectableText(
                  recoveryCode!,
                  style: const TextStyle(fontSize: 16, letterSpacing: 1.5),
                ),
                subtitle: const Text(
                  'Используйте его, если приложение будет переустановлено',
                ),
                trailing: IconButton(
                  tooltip: S.copied,
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: recoveryCode!));
                    showAppSnack(context, S.copied);
                  },
                ),
              )
            else
              const ListTile(
                leading: Icon(Icons.emergency_outlined),
                title: Text('Код восстановления не найден'),
                subtitle: Text('Обновите приложение и пересоздайте аккаунт'),
              ),
          ]),
          _section(S.settingsSpaces, [
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text(S.spacesTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/home/spaces'),
            ),
          ]),
          _section(S.settingsServers, [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text(S.settingsServers),
              subtitle: Text(app.activeServer?.name ?? '—'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/home/servers'),
            ),
          ]),
          _section('Обновление', [
            ListTile(
              leading: const Icon(Icons.system_update_alt_outlined),
              title: const Text('Проверить обновления'),
              subtitle: Text('Версия $_appVersion'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _checkForUpdate(),
            ),
          ]),
          _section('Диагностика', [
            ListTile(
              leading: const Icon(Icons.settings_suggest_outlined),
              title: const Text('Отправить логи разработчику'),
              subtitle: const Text('Тестовый режим: пришлёт служебный лог (не сообщения)'),
              onTap: () => _sendLogs(),
            ),
          ]),
          _section(S.settingsAbout, [
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(S.settingsAbout),
              subtitle: Text(S.settingsVersion),
            ),
          ]),
          _section('', [
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.danger),
              title: const Text(
                S.settingsLogout,
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () => _confirmLogout(),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _profileHeader(user) {
    final avatarUrl = _fullPhotoUrl(user.photoPath as String? ?? '');
    return Container(
      padding: const EdgeInsets.all(20),
      color: AppColors.surface,
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppColors.accent.withValues(alpha: 0.2),
            child: avatarUrl.isNotEmpty
                ? ClipOval(
                    child: ServerImage(
                      avatarUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: Text(
                        user.title.isNotEmpty
                            ? user.title[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                  )
                : Text(
                    user.title.isNotEmpty ? user.title[0].toUpperCase() : '?',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                Text(
                  user.handle,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 4),
                StatusChip(
                  text: switch (user.role) {
                    'SUPER_ADMIN' => 'Владелец сервера',
                    'FAMILY_MEMBER' => 'Член семьи',
                    _ => 'Пользователь',
                  },
                  color: user.isAdmin ? AppColors.accent : AppColors.accentAlt,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: S.edit,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.go('/home/profile/edit'),
          ),
        ],
      ),
    );
  }

  /// Полный URL фото из относительного пути (например /uploads/xxx.jpg).
  String _fullPhotoUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = ApiClient.instance.baseUrl;
    if (base.isEmpty) return path;
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }

  Widget _section(String title, List<Widget> tiles) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              title,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ...tiles,
        const Divider(height: 1),
      ],
    );
  }


  /// Тумблер статусов прочтения: хранится локально в настройках Hive.
  /// Выключенный — мы не шлём подтверждений и не видим статусы своих
  /// сообщений (собеседник тоже не увидит «прочитано» от нас).
  Widget _receiptsSwitch() {
    final enabled = HiveService.instance.settings['show_receipts'] as bool? ?? true;
    return SwitchListTile(
      secondary: const Icon(Icons.visibility_outlined),
      title: const Text('Статусы сообщений'),
      subtitle: const Text(
        'Отправлено / Получено / Прочитано. '
        'Выключите — и собеседники не узнают, что вы прочли сообщения, '
        'но и вы не будете видеть их статусы.',
      ),
      value: enabled,
      onChanged: (v) async {
        final settings = HiveService.instance.settings;
        settings['show_receipts'] = v;
        await HiveService.instance.saveSettings(settings);
        setState(() {});
      },
    );
  }

  /// Тумблер показа индикатора «онлайн» у контактов и в чатах.
  Widget _onlineSwitch() {
    final enabled = HiveService.instance.settings['show_online_status'] as bool? ?? true;
    return SwitchListTile(
      secondary: const Icon(Icons.circle_outlined),
      title: const Text('Индикатор «онлайн»'),
      subtitle: const Text(
        'Показывать зелёную точку, если собеседник сейчас в приложении.',
      ),
      value: enabled,
      onChanged: (v) async {
        final settings = HiveService.instance.settings;
        settings['show_online_status'] = v;
        await HiveService.instance.saveSettings(settings);
        setState(() {});
      },
    );
  }

  String get _ringtoneName {
    final v = HiveService.instance.settings['ringtone'] as String?;
    return (v != null && v.trim().isNotEmpty) ? v.trim() : 'ringtone';
  }

  String _ringtoneLabel(String name) => _ringtoneOptions[name] ?? name;

  Future<void> _showRingtonePicker() async {
    final current = _ringtoneName;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Рингтон звонка',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in _ringtoneOptions.entries)
                    ListTile(
                      leading: Radio<String>(
                        value: entry.key,
                        groupValue: current,
                        onChanged: (v) {},
                      ),
                      title: Text(entry.value),
                      subtitle: Text('@raw/${entry.key}'),
                      trailing: IconButton(
                        tooltip: 'Прослушать',
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: () => _previewRingtone(entry.key),
                      ),
                      onTap: () {
                        Navigator.pop(ctx, entry.key);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || selected == current) return;
    final settings = HiveService.instance.settings;
    settings['ringtone'] = selected;
    await HiveService.instance.saveSettings(settings);
    setState(() {});
    showAppSnack(context, 'Рингтон сохранён');
  }

  /// Предпрослушивание рингтона коротким нативным циклом.
  void _previewRingtone(String name) {
    const channel = MethodChannel('mesenger/incoming_ring');
    channel.invokeMethod('startRing', {'caller': 'Прослушивание', 'ringtone': name});
    Future.delayed(const Duration(seconds: 3), () {
      channel.invokeMethod('stopRing');
    });
  }

  Future<void> _showCallLog() async {
    final text = await CallLog.instance.read();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Лог звонков',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Скопировать',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: text));
                      if (mounted) showAppSnack(context, 'Лог скопирован');
                    },
                  ),
                ],
              ),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _cachedVersion = '';

  String get _appVersion {
    if (_cachedVersion.isEmpty) {
      // Загружается асинхронно при первом обращении.
      PackageInfo.fromPlatform().then((p) {
        _cachedVersion = '${p.version}+${p.buildNumber}';
        if (mounted) setState(() {});
      });
    }
    return _cachedVersion.isEmpty ? '0.1.0' : _cachedVersion;
  }

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final res = await ApiClient.instance.checkUpdate();
      if (res['update'] != true) {
        if (mounted) showAppSnack(context, 'У вас актуальная версия');
        return;
      }
      final newVersion = res['version']?.toString() ?? '';
      final apkPath = res['apk']?.toString() ?? '';
      final notes = res['notes']?.toString() ?? '';
      if (apkPath.isEmpty || newVersion.isEmpty) {
        if (mounted) showAppSnack(context, 'Нет ссылки на обновление', error: true);
        return;
      }
      // Сравниваем по buildNumber (растёт с каждой сборкой), а не по строке
      // version (всегда 0.1.0) — иначе каждая новая сборка не находится.
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;
      final remoteBuild = (res['build'] as num?)?.toInt() ?? 0;
      final need = remoteBuild > currentBuild;
      if (!need) {
        if (mounted) showAppSnack(context, 'У вас актуальная версия');
        return;
      }
      await CallLog.instance.write('UPDATE found build=$remoteBuild (current=$currentBuild)');
      var url = ApiClient.instance.photoUrl(apkPath);
      // Cache-bust: операторы кэшируют большой APK и отдают stale-байты
      // под свежим манифестом (хеш не сходится) — делаем URL уникальным.
      final sep = url.contains('?') ? '&' : '?';
      url = '$url${sep}build=$remoteBuild';
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Доступно обновление $newVersion'),
          content: Text(notes.isEmpty ? 'Скачать новую версию?' : '$notes\n\nСкачать?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Скачать')),
          ],
        ),
      );
      if (go == true && mounted) {
        setState(() => _updating = true);
        showAppSnack(context, 'Скачивание обновления…');
        unawaited(_downloadAndInstall(url, res['sha256']?.toString() ?? ''));
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Ошибка проверки обновления', error: true);
    }
  }

  /// Скачивает APK и запускает установку. Если приложение ещё не получило
  /// разрешение «Установка из этого источника», ждём, пока пользователь
  /// включит его в системных настройках (проверяем нативным MethodChannel),
  /// и автоматически запускаем установку.
  Future<String> _fileSha256(File f) async {
    final h = await Sha256().hash(await f.readAsBytes());
    return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Сверка скачанного APK: хеш из манифеста + подпись релизным ключом
  /// (только Android). false = файл недоверенный, ставить нельзя.
  Future<bool> _verifyApk(File apkFile, String expectedSha256) async {
    try {
      if (expectedSha256.isNotEmpty) {
        final actual = await _fileSha256(apkFile);
        await CallLog.instance.write(
            'UPDATE sha256 ok=${actual.toLowerCase() == expectedSha256.toLowerCase()}');
        if (actual.toLowerCase() != expectedSha256.toLowerCase()) return false;
      }
      if (Platform.isAndroid) {
        String cert = '';
        try {
          cert = await channel.invokeMethod<String>(
                'apkSignerSha256', {'path': apkFile.path},
              ) ??
              '';
        } catch (_) {}
        await CallLog.instance.write(
            'UPDATE cert match=${cert.toLowerCase() == _releaseCertSha256}');
        if (cert.toLowerCase() != _releaseCertSha256) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _downloadAndInstall(String url, String expectedSha256) async {
    channel = const MethodChannel('mesenger/incoming_ring');
    try {
      final dir = await getApplicationCacheDirectory();
      final dlDir = Directory('${dir.path}/downloads');
      if (!await dlDir.exists()) await dlDir.create(recursive: true);
      final apkFile = File('${dlDir.path}/app-release.apk');
      // Полный APK ~110 МБ. Если dio «завершил» скачивание, но файл
      // заметно меньше — загрузка оборвалась (сеть/лимит). Повторяем
      // до 3 раз, пока не скачаем целиком.
      const minSize = 100 * 1024 * 1024;
      int size = 0;
      for (var attempt = 1; attempt <= 3; attempt++) {
        await CallLog.instance.write('UPDATE dl start attempt=$attempt path=${apkFile.path}');
        size = await ApiClient.instance.downloadFile(url, apkFile.path);
        await CallLog.instance.write('UPDATE dl ok size=$size');
        if (size >= minSize) break;
        await CallLog.instance.write('UPDATE dl TOO SMALL, retry');
      }
      if (size < minSize) {
        if (mounted) {
          showAppSnack(context, 'Скачивание прервалось, попробуйте ещё раз', error: true);
        }
        return;
      }

      final trusted = await _verifyApk(apkFile, expectedSha256);
      if (!trusted) {
        try {
          await apkFile.delete();
        } catch (_) {}
        await CallLog.instance.write('UPDATE VERIFY FAIL, file deleted');
        if (mounted) {
          showAppSnack(
            context,
            'Обновление не прошло проверку подлинности и удалено',
            error: true,
          );
        }
        return;
      }

      // Ждём разрешение «Установка из этого источника» (до 90с), если его нет.
      final canInstall = await channel.invokeMethod<bool>('installPermission');
      if (canInstall != true) {
        await CallLog.instance.write('UPDATE permission: prompting');
        final r1 = await channel.invokeMethod<String>('installApk', {
          'path': apkFile.path,
        });
        await CallLog.instance.write('UPDATE install first=$r1');
        if (r1 == 'no_permission') {
          // Пользователь сейчас в системных настройках — периодически проверяем.
          var granted = false;
          for (var i = 0; i < 30; i++) {
            await Future.delayed(const Duration(seconds: 3));
            final g = await channel.invokeMethod<bool>('installPermission');
            if (g == true) { granted = true; break; }
          }
          if (!granted && mounted) {
            showAppSnack(
              context,
              'Разрешите установку из этого источника в настройках Android и повторите',
              error: true,
            );
            return;
          }
        }
      }

      final r2 = await channel.invokeMethod<String>('installApk', {
        'path': apkFile.path,
      });
      await CallLog.instance.write('UPDATE install result=$r2');
      if (mounted) {
        if (r2 == 'ok') {
          showAppSnack(context, 'Установка запущена системой');
        } else {
          showAppSnack(
            context,
            _installErrorText(r2 ?? 'launch_failed'),
            error: true,
          );
        }
      }
    } catch (e) {
      await CallLog.instance.write('UPDATE FAIL: $e');
      if (mounted) showAppSnack(context, 'Ошибка скачивания обновления', error: true);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  static String _installErrorText(String code) {
    switch (code) {
      case 'no_permission':
        return 'Разрешите установку из этого источника в настройках Android и повторите';
      case 'file_missing':
        return 'Файл обновления не найден на устройстве';
      case 'settings_launch_failed':
        return 'Не удалось открыть настройки установки';
      case 'launch_failed':
        return 'Не удалось запустить установку';
      default:
        return 'Не удалось установить обновление';
    }
  }

  Future<void> _sendLogs() async {
    try {
      final logs = await CallLog.instance.read();
      if (logs.isEmpty || logs == '(лог пуст)') {
        if (mounted) showAppSnack(context, 'Лог пуст — сначала совершите звонок');
        return;
      }
      final comment = await _askComment();
      if (comment == null) return; // пользователь отменил отправку
      final info = await PackageInfo.fromPlatform();
      await ApiClient.instance.sendDiagLogs(
        device: SecureStore.instance.deviceId,
        version: info.version,
        logs: logs,
        comment: comment,
      );
      if (mounted) showAppSnack(context, 'Лог отправлен разработчику');
    } catch (e) {
      if (mounted) showAppSnack(context, 'Не удалось отправить лог', error: true);
    }
  }

  /// Диалог с описанием проблемы перед отправкой логов.
  /// Возвращает null, если пользователь отменил.
  Future<String?> _askComment() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Что не так работает?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Опишите проблему — это поможет разработчику быстрее понять, '
              'что именно произошло. Вместе с комментарием отправится и лог.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Например: не приходит звук при звонке…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    return (ok == true) ? text : null;
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.settingsLogout),
        content: const Text(S.settingsLogoutConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(S.ok)),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appStateProvider.notifier).logout();
    }
  }
}
