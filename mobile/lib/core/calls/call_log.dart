import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Диагностический лог звонков в файл на устройстве. Пишет каждый шаг
/// accept/call, чтобы при нативном краше пользователь мог переслать
/// файл crash.log (иначе строки Android-краха недоступны удалённо).
class CallLog {
  CallLog._();

  static final CallLog instance = CallLog._();

  static const _maxBytes = 256 * 1024;

  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/call_log.txt');
      _file = f;
      if (!await f.exists()) {
        await f.create();
      }
    } catch (_) {}
  }

  File? _file;

  Future<String> read() async {
    try {
      if (_file == null) await init();
      final f = _file;
      if (f == null) return '(лог пуст)';
      if (!await f.exists()) return '(лог пуст)';
      final all = await f.readAsString();
      return all.isEmpty ? '(лог пуст)' : all;
    } catch (e) {
      return 'не удалось прочитать лог: $e';
    }
  }

  Future<void> write(String line) async {
    try {
      if (_file == null) await init();
      final f = _file;
      if (f == null) return;
      final lineWithTs = '[${DateTime.now().toIso8601String()}] $line\n';
      await f.writeAsString(lineWithTs, mode: FileMode.append);
      if (await f.length() > _maxBytes) {
        // Храним только хвост лога.
        final all = await f.readAsString();
        await f.writeAsString(all.substring(all.length - _maxBytes ~/ 2));
      }
    } catch (_) {}
  }
}