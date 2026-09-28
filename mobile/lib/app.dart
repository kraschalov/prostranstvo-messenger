import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/core/calls/call_service.dart';
import 'package:mesenger/core/router/app_router.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/features/call/call_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MesengerApp extends ConsumerStatefulWidget {
  const MesengerApp({super.key});

  @override
  ConsumerState<MesengerApp> createState() => _MesengerAppState();
}

class _MesengerAppState extends ConsumerState<MesengerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CallService.instance.onIncoming = (session) {
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(session: session),
        ),
      );
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // При возврате из фона после входящего звонка завершаем отложенный
    // «Ответить» (маркер пишет фоновый колбэк колкита callkitBackgroundHandler).
    if (state == AppLifecycleState.resumed) {
      CallService.instance.acceptDeferredIfPending();
    }
    // Диагностика: фиксируем переходы фон/передний план, чтобы понять,
    // когда именно рвётся WebSocket при сворачивании приложения.
    try {
      CallLog.instance.write('LIFECYCLE -> $state');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Пространство',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      routerConfig: router,
      builder: (context, child) {
        ErrorWidget.builder = (details) => Material(
              color: AppColors.background,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Ошибка интерфейса',
                        style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        '${details.exception}',
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: '${details.exception}'));
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Скопировать ошибку'),
                      ),
                    ],
                  ),
                ),
              ),
            );
        return child!;
      },
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
